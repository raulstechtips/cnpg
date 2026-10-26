# cnpg

Helm chart `cnpg-cluster`: one CloudNativePG (CNPG) Postgres cluster with tuned defaults.

## Purpose

One Helm release makes one CNPG `Cluster` and everything that belongs to it:

- The `Cluster`, with Postgres parameters calculated from the pod limits, the WAL volume size and the disk type.
- One `Database` object per entry in `databases`.
- One `InfisicalStaticSecret` per role (and one for the bootstrap owner). It writes a `kubernetes.io/basic-auth` Secret with `username` = the role name and the password from Infisical. The target uses `creationPolicy: Orphan`: the Secret has no owner, so deleting the `InfisicalStaticSecret` never deletes it.
- A cert-manager `Certificate` for the `-rw`, `-ro` and `-r` services, from the internal CA. Its Secret gets the `cnpg.io/reload` label (through `secretTemplate`), so CNPG reloads Postgres when cert-manager renews the certificate.
- A `ScheduledBackup` (volume snapshots, which Longhorn uploads to the S3 backup target), and a retention `CronJob`.
- Optional PgBouncer `Pooler` objects.

The chart has no upstream dependency. It is published to GHCR (`oci://ghcr.io/raulstechtips/charts/cnpg-cluster`), and not to Harbor, because the Harbor database runs on `pg-prod`.

## Use it from Argo CD

The Cluster name is the Helm release name, and the namespace is the release namespace. Set both in the Application:

```yaml
spec:
  sources:
    - repoURL: ghcr.io/raulstechtips/charts
      chart: cnpg-cluster
      targetRevision: <chart version>
      helm:
        releaseName: pg-prod          # the Cluster name
        valueFiles:
          - $values/apps/dev/cnpg-prod.yaml
  destination:
    namespace: prod                   # the Cluster namespace
```

If `releaseName` is missing, Argo CD uses the Application name, and the chart makes a new, empty cluster with that name. The Argo diff then shows a complete new Cluster. Do not sync it.

A minimal values file:

```yaml
bootstrap:
  database: app
roles:
  - name: pg-myapp
    passwordSecret:
      secretPath: /myapp/postgres
      reflectTo: [myapp]
databases:
  - name: myapp
    owner: pg-myapp
```

## Before first install

These must already exist. The chart reads them, but never creates them:

- The `InfisicalAuth` in `infisical.authRef` (default `infisical-prod-universal-auth` in `default`).
- In Infisical: the owner password at `bootstrap.passwordSecret.secretPath` (default `/cnpg/<release>/users/admin`), and one password per role at its `secretPath`.
- The cert-manager issuer in `tls.issuerRef` and the CA Secret in `tls.caSecret`, in the release namespace.
- The VolumeSnapshotClass in `backup.volumeSnapshotClass`.

## Calculated parameters

The chart calculates these parameters. A value in `postgresql.parameters` always wins.

| Parameter | Formula | Default result |
| --- | --- | --- |
| `max_connections` | fixed | 100 |
| `shared_buffers` | 25% of `resources.limits.memory` | 256MB |
| `effective_cache_size` | 75% of the memory limit | 768MB |
| `maintenance_work_mem` | memory limit / 16, min 64MB, max 1GB | 64MB |
| `work_mem` | (memory limit - shared_buffers) / (max_connections x 3), min 4MB | 4MB |
| `max_wal_size` | 25% of the WAL budget | 2560MB |
| `min_wal_size` | 25% of `max_wal_size` | 640MB |
| `max_slot_wal_keep_size` | 50% of the WAL budget | 5120MB |
| `wal_keep_size` | 10% of the WAL budget | 1024MB |
| `random_page_cost` | `hdd` 4, `ssd` 1.1 | 4 |
| `effective_io_concurrency` | `hdd` 2, `ssd` 200 | 2 |
| `maintenance_io_concurrency` | `hdd` 10, `ssd` 100 | 10 |
| `max_parallel_workers` | `resources.limits.cpu`, rounded up | 2 |
| `max_parallel_workers_per_gather` | max(1, cores / 2) | 1 |
| `max_parallel_maintenance_workers` | max(1, cores / 2) | 1 |
| `checkpoint_timeout`, `wal_compression`, `jit`, `huge_pages` | fixed | 15min, lz4, off, off |

The WAL budget is `walStorage.size`. Without a WAL volume, it is 25% of `storage.size`.
All other parameters (autovacuum, logging, timeouts) stay at the Postgres defaults.

## Values reference

| Key | Default | Meaning |
| --- | --- | --- |
| `image` | `ghcr.io/cloudnative-pg/postgresql:17.4` | Postgres image. |
| `instances` | `3` | Primary plus replicas. |
| `affinity.podAntiAffinityType` | `required` | One instance per node. |
| `primaryUpdateStrategy` / `primaryUpdateMethod` | `unsupervised` / `switchover` | Rolling updates end with a switchover. |
| `enableSuperuserAccess` | `false` | `true` makes `<release>-superuser`. |
| `resources` | requests `10m`/`256Mi`, limits `2`/`1Gi` | Both limits are required. |
| `storage.size` / `.storageClass` / `.diskType` | `10Gi` / Longhorn local / `hdd` | `diskType` is `hdd` or `ssd`. |
| `walStorage.enabled` / `.size` | `true` / `10Gi` | Separate WAL volume. |
| `postgresql.parameters` | `{}` | Any parameter. Wins over the calculated value. |
| `infisical.*` | shared prod connection | `authRef`, `projectSlug`, `environmentSlug`, `refreshInterval`. |
| `bootstrap.database` | `app` | initdb database. The owner is `<release>-admin`. |
| `bootstrap.passwordSecret` | see `values.yaml` | Same fields as a role `passwordSecret`, without `reflectTo`. |
| `roles[]` | `[]` | `name`, `comment`, `ensure`, `login` (true), `superuser` (false), `createdb` (false), `createrole` (false), `inherit` (true), `connectionLimit` (-1), `inRoles`, `replication`, `bypassrls`, `validUntil`, `passwordSecret`. |
| `roles[].passwordSecret` | | `secretPath` (required), `passwordKey` (`password`), `name` (`<role>-credentials`), `environmentSlug`, `reflectTo` (namespaces for reflector copies). |
| `databases[]` | `[]` | `name`, `owner` (must be in `roles`), `ensure`, `databaseReclaimPolicy` (`retain`), `allowConnections` (true), plus the other CNPG Database fields. |
| `tls.enabled` | `true` | `false` uses the CNPG self-signed CA. |
| `backup.enabled` / `.schedule` / `.retention` | `true` / daily 00:00 / `14d` | The retention job never deletes the newest completed Backup. |
| `poolers[]` | `[]` | `name`, `type` (`rw`), `instances` (2), `poolMode` (`session`), `parameters`, `resources`. |

## Safety rules

- Removing a role from `roles` does not drop it. Set `ensure: absent`.
- Databases use `databaseReclaimPolicy: retain`. Deleting a `Database` object keeps the data. Set `ensure: absent` to drop a database.
- The render fails when a database owner is not in `roles`, when a limit is missing, or when the poolers' `instances x max_db_connections` reaches `max_connections`.
- `values.schema.json` rejects unknown keys, so a typo fails the render.

## Development

```sh
helm lint --strict charts -f charts/ci/all-on-values.yaml
helm unittest charts
```

CI (Jenkins shared library) runs lint, the unit tests, kubeconform, Trivy and Opengrep, then publishes the chart to GHCR.
