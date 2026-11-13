# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `fullnameOverride`, which replaces the Cluster name. An existing cluster sets it to its current name (for example `fullnameOverride: pg-prod`) before it upgrades ([SWEALTH-329](https://raulstechtips.atlassian.net/browse/SWEALTH-329)).
- Add `adminAggregateRole.enabled` (default `false`). It makes a ClusterRole that aggregates to `admin`, so namespace admins such as `jenkins-deployer` can manage namespaced CNPG resources ([SWEALTH-329](https://raulstechtips.atlassian.net/browse/SWEALTH-329)).

### Changed

- Name the Cluster `<release>-cnpg-cluster`, so its pods are `<release>-cnpg-cluster-N`. The services, Secrets, owner role, certificate and backups take their names from it. An existing cluster must set `fullnameOverride` before it upgrades, or the upgrade creates a new, empty cluster ([SWEALTH-329](https://raulstechtips.atlassian.net/browse/SWEALTH-329)).

### Fixed

## [0.1.0] - 2026-11-08

[Unreleased]: https://github.com/raulstechtips/cnpg/compare/0.1.0...HEAD
[0.1.0]: https://github.com/raulstechtips/cnpg/releases/tag/0.1.0
