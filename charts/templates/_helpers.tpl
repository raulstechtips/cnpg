{{/* Common labels for every object this chart renders. */}}
{{- define "cnpg-cluster.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Bootstrap owner role: "<release>-admin". */}}
{{- define "cnpg-cluster.ownerName" -}}
{{- printf "%s-admin" .Release.Name -}}
{{- end -}}

{{/*
Converts a Kubernetes memory quantity (for example 1Gi, 512Mi, 1.5Gi, 2G, 1073741824) to whole MiB.
*/}}
{{- define "cnpg-cluster.toMiB" -}}
{{- $q := toString . -}}
{{- $mib := 0.0 -}}
{{- if hasSuffix "Ti" $q -}}{{- $mib = mulf (float64 (trimSuffix "Ti" $q)) 1048576 -}}
{{- else if hasSuffix "Gi" $q -}}{{- $mib = mulf (float64 (trimSuffix "Gi" $q)) 1024 -}}
{{- else if hasSuffix "Mi" $q -}}{{- $mib = float64 (trimSuffix "Mi" $q) -}}
{{- else if hasSuffix "Ki" $q -}}{{- $mib = divf (float64 (trimSuffix "Ki" $q)) 1024 -}}
{{- else if hasSuffix "T" $q -}}{{- $mib = divf (mulf (float64 (trimSuffix "T" $q)) 1000000000000) 1048576 -}}
{{- else if hasSuffix "G" $q -}}{{- $mib = divf (mulf (float64 (trimSuffix "G" $q)) 1000000000) 1048576 -}}
{{- else if hasSuffix "M" $q -}}{{- $mib = divf (mulf (float64 (trimSuffix "M" $q)) 1000000) 1048576 -}}
{{- else if hasSuffix "k" $q -}}{{- $mib = divf (mulf (float64 (trimSuffix "k" $q)) 1000) 1048576 -}}
{{- else -}}{{- $mib = divf (float64 $q) 1048576 -}}
{{- end -}}
{{- int64 (floor $mib) -}}
{{- end -}}

{{/* Converts a Kubernetes CPU quantity (2, "2", "1500m", "0.5") to whole cores, rounded up. */}}
{{- define "cnpg-cluster.toCores" -}}
{{- $q := toString . -}}
{{- $cores := 0.0 -}}
{{- if hasSuffix "m" $q -}}{{- $cores = divf (float64 (trimSuffix "m" $q)) 1000 -}}
{{- else -}}{{- $cores = float64 $q -}}
{{- end -}}
{{- max 1 (int64 (ceil $cores)) -}}
{{- end -}}

{{/*
PostgreSQL parameters. The chart calculates the hardware-derived values, then the values in
postgresql.parameters win over them. Every value is a string, as CNPG expects.
*/}}
{{- define "cnpg-cluster.parameters" -}}
{{- $v := .Values -}}
{{- $limits := $v.resources.limits | default dict -}}
{{- $memLimit := required "resources.limits.memory is required, because the chart calculates the memory parameters from it" $limits.memory -}}
{{- $cpuLimit := required "resources.limits.cpu is required, because the chart calculates the parallel worker parameters from it" $limits.cpu -}}
{{- $user := $v.postgresql.parameters | default dict -}}
{{- $mem := int64 (include "cnpg-cluster.toMiB" $memLimit) -}}
{{- $cores := int64 (include "cnpg-cluster.toCores" $cpuLimit) -}}
{{- $maxConn := int64 (get $user "max_connections" | default "100") -}}
{{- $sharedBuffers := div $mem 4 -}}
{{- $workMem := max 4 (div (sub $mem $sharedBuffers) (mul $maxConn 3)) -}}
{{- $maintenance := min 1024 (max 64 (div $mem 16)) -}}
{{- $walBudget := 0 -}}
{{- if $v.walStorage.enabled -}}
{{- $walBudget = int64 (include "cnpg-cluster.toMiB" $v.walStorage.size) -}}
{{- else -}}
{{- $walBudget = div (int64 (include "cnpg-cluster.toMiB" $v.storage.size)) 4 -}}
{{- end -}}
{{- $maxWal := div $walBudget 4 -}}
{{- $halfCores := max 1 (div $cores 2) -}}
{{- $disk := dict "hdd" (dict "random_page_cost" "4" "effective_io_concurrency" "2" "maintenance_io_concurrency" "10") "ssd" (dict "random_page_cost" "1.1" "effective_io_concurrency" "200" "maintenance_io_concurrency" "100") -}}
{{- $calc := dict
  "max_connections" (toString $maxConn)
  "shared_buffers" (printf "%dMB" $sharedBuffers)
  "effective_cache_size" (printf "%dMB" (div (mul $mem 3) 4))
  "maintenance_work_mem" (printf "%dMB" $maintenance)
  "work_mem" (printf "%dMB" $workMem)
  "huge_pages" "off"
  "max_wal_size" (printf "%dMB" $maxWal)
  "min_wal_size" (printf "%dMB" (div $maxWal 4))
  "max_slot_wal_keep_size" (printf "%dMB" (div $walBudget 2))
  "wal_keep_size" (printf "%dMB" (div $walBudget 10))
  "checkpoint_timeout" "15min"
  "wal_compression" "lz4"
  "jit" "off"
  "max_parallel_workers" (toString $cores)
  "max_parallel_workers_per_gather" (toString $halfCores)
  "max_parallel_maintenance_workers" (toString $halfCores)
-}}
{{- $calc = merge $calc (get $disk $v.storage.diskType) -}}
{{- $out := dict -}}
{{- range $k, $val := (mergeOverwrite $calc $user) -}}
{{- $_ := set $out $k (toString $val) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Name of the Secret that holds a role password. Arguments: dict "role" <name> "secret" <passwordSecret>.
*/}}
{{- define "cnpg-cluster.secretName" -}}
{{- $s := .secret | default dict -}}
{{- $s.name | default (printf "%s-credentials" .role) -}}
{{- end -}}

{{/*
InfisicalStaticSecret that writes one basic-auth Secret: username = the role name, password from
Infisical. Arguments: dict "root" $ "role" <name> "secret" <passwordSecret>.
*/}}
{{- define "cnpg-cluster.roleSecret" -}}
{{- $root := .root -}}
{{- $s := .secret | default dict -}}
{{- $name := include "cnpg-cluster.secretName" . -}}
{{- $inf := $root.Values.infisical -}}
apiVersion: secrets.infisical.com/v1beta1
kind: InfisicalStaticSecret
metadata:
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "cnpg-cluster.labels" $root | nindent 4 }}
spec:
  infisicalAuthRef:
    name: {{ required "infisical.authRef.name is required" $inf.authRef.name | quote }}
    namespace: {{ required "infisical.authRef.namespace is required" $inf.authRef.namespace | quote }}
  syncOptions:
    refreshInterval: {{ $inf.refreshInterval | quote }}
  sources:
    - projectSlug: {{ required "infisical.projectSlug is required" $inf.projectSlug | quote }}
      environmentSlug: {{ $s.environmentSlug | default (required "infisical.environmentSlug is required" $inf.environmentSlug) | quote }}
      secretPath: {{ required (printf "passwordSecret.secretPath is required for role %s" .role) $s.secretPath | quote }}
  targets:
    - name: {{ $name }}
      namespace: {{ $root.Release.Namespace }}
      kind: Secret
      secretType: kubernetes.io/basic-auth
      creationPolicy: Owner
      metadata:
        labels:
          cnpg.io/reload: "true"
        {{- if $s.reflectTo }}
        annotations:
          reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
          reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: {{ join "," $s.reflectTo | quote }}
        {{- else }}
        annotations: {}
        {{- end }}
      template:
        engineVersion: v1
        data:
          username: {{ .role | quote }}
          password: {{ printf "{{ .%s.Value }}" ($s.passwordKey | default "password") | quote }}
{{- end -}}
