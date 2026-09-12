---
title: "Paperless-ngx Helm Chart"
description: "A community Helm chart for deploying Paperless-ngx on Kubernetes."
---

# Paperless-ngx Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/paperless)](https://artifacthub.io/packages/helm/paperless/paperless-ngx)
[![Release](https://img.shields.io/github/v/release/CodeOpsMS/paperless-ngx-helm-chart?label=Chart%20Version)](https://github.com/CodeOpsMS/paperless-ngx-helm-chart/releases)
[![Helm CI](https://github.com/CodeOpsMS/paperless-ngx-helm-chart/actions/workflows/helm-ci.yml/badge.svg)](https://github.com/CodeOpsMS/paperless-ngx-helm-chart/actions/workflows/helm-ci.yml)
[![License status](https://img.shields.io/badge/license-see%20NOTICE-orange)](NOTICE)

> **This is a community-maintained Helm chart packaged by CodeOpsMS.**
> It is not an official Paperless-ngx chart and does not receive official
> support from the Paperless-ngx project.

> **Stable Paperless 3 release:** Chart `0.4.0` deploys
> Paperless-ngx 3.1.3 and replaces `0.3.23` as the stable default.
> Existing Paperless 2 installations must follow [UPGRADE-0.4.md](UPGRADE-0.4.md)
> before upgrading. Pin `--version 0.3.23` until that migration is prepared.

This chart deploys Paperless-ngx 3.1.3 with optional PostgreSQL and
Valkey dependencies. The default deployment retains legacy PostgreSQL 17.6 for
upgrade testing and uses Valkey
9.0.5. All default container images are pinned to immutable multi-platform
digests.

## Project links

- **Chart source:** <https://github.com/CodeOpsMS/paperless-ngx-helm-chart>
- **Published Helm repository:** <https://codeopsms.github.io/paperless-ngx-helm-chart/>
- **Artifact Hub:** <https://artifacthub.io/packages/helm/paperless/paperless-ngx>
- **Paperless-ngx documentation:** <https://docs.paperless-ngx.com/>
- **Paperless-ngx source:** <https://github.com/paperless-ngx/paperless-ngx>
- **Forked from:** [WrenIX paperless-ngx Helm chart](https://codeberg.org/wrenix/helm-charts/src/branch/main/paperless-ngx)

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| CodeOpsMS | <codeopsms@users.noreply.github.com> | <https://github.com/CodeOpsMS> |

## Requirements

- Kubernetes `1.34` or newer
- Helm 3 or Helm 4 (the exact maintained versions are pinned in CI)
- An x86-64-v2 capable CPU on amd64 for classifier support, or a supported arm64 node
- Persistent storage for production use

Kubernetes 1.34 is the chart's intentional maintained-and-tested support floor,
not a claim that every rendered Kubernetes API first appeared in 1.34. Older
clusters are rejected because they are outside this release's CI/support matrix.

On older amd64 CPUs without SSE4.2, upstream documents a restricted setup with
`PAPERLESS_TRAIN_TASK_CRON=disable` that gives up classifier-based matching.
The separate 3.0.5 OCR failure on this hardware is fixed in the 3.1 line; test
the actual hardware before relying on this configuration. See
[UPGRADE-0.4.md](UPGRADE-0.4.md) for details.

The tested dependency versions for chart 0.4.0 are:

| Component | Chart | Application |
|-----------|-------|-------------|
| PostgreSQL | `16.7.27` | `17.6.0` |
| Valkey | `0.9.4` | `9.0.5` |

The bundled `bitnamilegacy/postgresql` image is archived and no longer
maintained. PostgreSQL 17.6 is a legacy test baseline, not a current security
release. It remains in the 0.4 release line for compatibility with historical
upgrade baselines. For a new or production installation,
disable the bundled database and use a maintained external PostgreSQL 17
service ([17.11 at this review](https://www.postgresql.org/docs/17/release-17-11.html))
with independent backups and lifecycle management. Moving the bundled
dependency to PostgreSQL 18 is intentionally outside this migration release.
The Docker Official PostgreSQL image is not a drop-in replacement for the
Bitnami chart's entrypoint, environment variables, or data layout; do not change
only `postgresql.image.repository` to migrate a database.

## Installation

### Stable Helm repository install (Paperless 3)

```bash
helm repo add paperless https://codeopsms.github.io/paperless-ngx-helm-chart/
helm repo update
helm install paperless-ngx paperless/paperless-ngx \
  --version 0.4.0 \
  --namespace paperless-ngx \
  --create-namespace
```

Normal Helm version resolution now selects the stable Paperless 3 chart.
An unpinned `helm upgrade` of a Paperless 2 installation therefore crosses a
breaking application/database migration. Do not upgrade until the migration
guide, backups, and full application shutdown have been addressed.

### Stable OCI install (Paperless 3)

```bash
helm install paperless-ngx \
  oci://ghcr.io/codeopsms/helm-charts/paperless-ngx \
  --version 0.4.0 \
  --namespace paperless-ngx \
  --create-namespace
```

Historical chart versions remain addressable by explicit version:

| Chart version | Paperless-ngx | Purpose |
|---------------|---------------|---------|
| `0.3.23` | `2.20.15` | Last Paperless 2 release |
| `0.4.0-experimental.1` | `3.0.5` | Historical Paperless 3 preview |
| `0.4.0` | `3.1.3` | Current stable Paperless 3 release |

Chart 0.3.23 remains available for existing Paperless 2 installations, but it
is a historical release and does not receive Paperless 3 fixes or current
security updates. It is no longer the default; select it explicitly when
maintaining a Paperless 2 installation pending a controlled migration.

Use distinct release names and namespaces to run both versions in parallel:

```bash
helm install paperless-v2 \
  oci://ghcr.io/codeopsms/helm-charts/paperless-ngx \
  --version 0.3.23 \
  --namespace paperless-v2 \
  --create-namespace

helm install paperless-v3 \
  oci://ghcr.io/codeopsms/helm-charts/paperless-ngx \
  --version 0.4.0 \
  --namespace paperless-v3 \
  --create-namespace
```

Give the two releases separate ingress hosts, Secrets, databases, and persistent
volumes. Never attach the Paperless 2 and Paperless 3 releases to the same
PostgreSQL database, Valkey state, or Paperless data/media PVCs.

For production, store `PAPERLESS_SECRET_KEY`, database credentials, and any
external broker URL in Kubernetes Secrets and reference them through
`config.*.existingSecret`.

OIDC provider JSON commonly contains client credentials. Reference an existing
Secret with `env.PAPERLESS_SOCIALACCOUNT_PROVIDERS.valueFrom.secretKeyRef` rather
than putting it inline in `config.oidcProviders`; the schema rejects configuring
both sources simultaneously.

The Deployment never publishes hashes derived from Secret values in pod
annotations. Increment the non-sensitive `config.secretRevision` whenever a
change to another `config` value modifies the chart-managed Secret (including
`config.oidcProviders`), a scalar `env` value changes, or the contents of a
referenced Secret change without changing its name or key. This deliberately
triggers a Paperless rollout; never put a credential or credential hash in the
revision itself.

For the bundled database, `postgresql.auth` is the only credential and identity
source. Paperless reads its database name and user from that section and its
password directly from the exact Secret/key used by the PostgreSQL dependency.
Fresh installations generate random PostgreSQL passwords; normal in-cluster
Helm upgrades preserve the existing Secret values. Set
`postgresql.auth.existingSecret` for production GitOps rendering or externally
managed credentials. `config.database.*` is reserved for external databases and
SQLite; a non-SQLite external database must set exactly one of
`config.database.password` and `config.database.existingSecret.name`.

When the effective bundled PostgreSQL credentials are deliberately rotated,
increment `postgresql.credentialsRevision` in the same reviewed change. The
revision restarts Paperless without putting a password or password hash into
Deployment annotations. A normal upgrade that keeps the credentials unchanged
must leave the revision unchanged. `postgresql.namespaceOverride` is not
supported because the Paperless Deployment and the dependency Secret need to
remain in the release namespace.

The bundled Valkey connection is intentionally unauthenticated and does not use
TLS. If broker authentication or TLS is required, set `valkey.internal=false`
and provide the complete `redis://` or `rediss://` connection URL through
`config.redis.existingSecret`.

## Artifact Hub and GitHub Pages

GitHub Pages is active and serves the classic Helm repository. Artifact Hub
indexes that published repository directly.

| Field | Value |
|-------|-------|
| Repository name | `paperless` |
| Display name | `Paperless-ngx` |
| Repository URL | `https://codeopsms.github.io/paperless-ngx-helm-chart/` |

The repository name is part of the Artifact Hub package URL and cannot be
changed after registration.

## Upgrading

### From chart 0.3.x and Paperless 2

Chart 0.4.0 is a breaking upgrade from Paperless-ngx 2.20.15 to 3.1.3. Do not
upgrade from an older Paperless release, do not use `--reuse-values`, and do not
rely on `helm rollback` after the database migration has run.

Read [UPGRADE-0.4.md](UPGRADE-0.4.md) completely before upgrading. It contains
the required preflight checks, configuration mapping, backup and restore
procedure, controlled application shutdown, validation, and recovery steps.

PostgreSQL remains at 17.6, while Valkey is updated within major version 9 from
9.0.2 to 9.0.5. No database-engine or broker major migration is performed by
chart 0.4.0.

### Upgrading the previous Paperless 3 preview

Chart `0.4.0-experimental.1` with Paperless `3.0.5` can upgrade directly to
`0.4.0` with Paperless `3.1.3`.
Its existing v3 database does not need the v2 migration prerequisite or another
Whoosh/checksum conversion. Back up and rehearse recovery, drain tasks, stop
the application completely, and apply the reviewed values to the same database,
Secrets, and PVCs as described in [UPGRADE-0.4.md](UPGRADE-0.4.md).

Paperless 3.1 fixes the explicit `PAPERLESS_SEARCH_LANGUAGE` startup failure,
orphaned Tantivy segment growth, and custom-field workflow assignment problems
documented for 3.0.5. Search language is supported again; changing it rebuilds
the index. Version 3.1.3 includes the fix for
[GHSA-2jhj-xqrq-rmrq](https://github.com/paperless-ngx/paperless-ngx/security/advisories/GHSA-2jhj-xqrq-rmrq),
uses Python 3.14 in the official image, and respects archive settings for remote
OCR. Review optional OIDC role synchronization and remote OCR settings before
using them. API versions remain 9 and 10. Tika 4 and some complex Whoosh saved
queries remain incompatible, and network-scanner partial-file delivery needs
an environment-specific test; the upgrade guide covers these limitations.

`env.PAPERLESS_ENABLE_FLOWER` now requires a YAML boolean. Set `false` to
disable Flower; the chart renders an empty environment value because the image
treats non-empty strings such as `"false"` as enabled. A ServiceMonitor requires
both `prometheus.servicemonitor.enabled=true` and
`env.PAPERLESS_ENABLE_FLOWER=true`.

## Scaling and availability

`replicaCount`, HPA, and the RollingUpdate budgets remain configurable. The
strategy type stays `RollingUpdate` because Helm 4 server-side apply cannot
safely clear the old `rollingUpdate` field during a live switch to `Recreate`.
The default (`maxSurge: 0`, `maxUnavailable: 100%`) avoids creating an extra
application pod. It is not a substitute for the explicit scale-to-zero and
complete pod-termination wait in the upgrade guide, which prevents old and new
Paperless versions from overlapping during database migrations. This
disruptive default causes downtime on every rollout until the budgets are
changed after the migration has been accepted. The chart still runs
the Paperless web server, consumer, scheduler, and worker processes together in
one Deployment. Multiple replicas are therefore exposed as an expert option,
but this all-in-one topology has not been validated as a fully highly available
Paperless architecture. Test storage access modes, task scheduling, and upgrade
behavior for your environment before increasing the replica count.

HPA utilization targets require matching container requests:
`resources.requests.cpu` for a configured CPU target or Kubernetes' default CPU
metric when both targets are null, and `resources.requests.memory` for a memory
target. The chart rejects an HPA configuration whose required request is
missing because Kubernetes cannot calculate that utilization safely.

## Validation and automation

Every change is checked with Helm 3 and Helm 4, a strict values schema,
helm-unittest, fixed dependency-archive and container-image digests, Kubernetes
server-side dry runs, and a required Kubernetes 1.36 installation. One candidate
package is reused byte-for-byte by all installation and upgrade jobs. The
Paperless update PRs, release branches, and the daily workflow additionally test fresh installs
on Kubernetes 1.34-1.36 and upgrades from Paperless 2.20.15 and the previous
Paperless 3.0.5 preview across Helm 3 and Helm 4.

| Update | Automation policy |
|--------|-------------------|
| Paperless patch/minor | Opens a review PR and updates appVersion plus image digest |
| Paperless major | Requires a manually prepared migration PR |
| PostgreSQL/Valkey charts | Renovate opens separate review PRs |
| GitHub-owned Actions patch | A small allowlist may auto-merge after required checks; all other updates require review |
| Releases | A successful `main` CI run promotes its exact tested candidate; stable charts become Latest and the normal Helm default |

GitHub Pages is active. The Pages healthcheck verifies Artifact Hub repository
metadata and byte-identical SHA-256 chart packages across Pages, GitHub
Releases, and anonymous OCI access every day. It checks the latest stable
release, the current chart, and the historical 0.3.23 baseline.

## License and provenance

The combined chart does not currently have a confirmed overall license. The
imported WrenIX source and history still contain no license grant, so this
package must not be represented as entirely MIT licensed. Original CodeOpsMS
contributions are offered separately under the
[MIT terms for CodeOpsMS contributions](LICENSES/CodeOpsMS-MIT.txt); those terms
do not relicense the imported material.

Read [NOTICE](NOTICE) for provenance and the evidence still required to
establish redistribution rights. Artifact Hub intentionally receives no
package-wide license identifier while that status remains unresolved.
Paperless-ngx itself is a separate GPL-3.0 project.

## Values

### NetworkPolicy

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| networkPolicy.egress.database | list | `[]` | Rules for external PostgreSQL/Redis-compatible services. Required when an internal dependency is disabled. |
| networkPolicy.egress.dns | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | rule to access DNS |
| networkPolicy.egress.enabled | bool | `true` | activate egress no networkpolicy |
| networkPolicy.egress.extra | list | `[]` | allow additinal  egress (e.g. smtp, imap) |
| networkPolicy.enabled | bool | `false` | deploy networkpolicy |
| networkPolicy.ingress.http | list | `[]` | allow to http ports should be your ingress-controller |
| networkPolicy.ingress.metrics | list | `[]` | ingress for metrics port (e.g. prometheus) |

### Other Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` | Must be greater than or equal to autoscaling.minReplicas. |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| config.apps | string | `""` | Additional Django applications. |
| config.database.engine | string | `"postgresql"` | External database engine. Keep postgresql when the bundled dependency is enabled. For MariaDB and SQLite, disable the bundled PostgreSQL dependency. SQLite ignores host, port, name, user, password and password Secret. |
| config.database.existingSecret.name | string | `""` | Existing Secret containing the database password. |
| config.database.existingSecret.passwordKey | string | `"password"` | Key in the existing Secret. |
| config.database.host | string | `""` | External database host. Ignored when postgresql.enabled is true. |
| config.database.name | string | `"paperless"` | External database name. Bundled database identity comes from postgresql.auth. |
| config.database.options | string | `""` | Engine-specific Paperless 3 database options, for example sslmode=require,pool.max_size=5 for PostgreSQL or timeout=20 for SQLite. |
| config.database.password | string | `""` | External database password. Set exactly one of this value and config.database.existingSecret.name for a non-SQLite external database. |
| config.database.port | string | `nil` | Database port. Empty lets Paperless select the engine default: 5432 for PostgreSQL or 3306 for MariaDB. |
| config.database.user | string | `"paperless"` | External database user. Bundled database identity comes from postgresql.auth. |
| config.oidcProviders | string | `nil` | Inline django-allauth provider configuration serialized as JSON. This may contain client credentials; for production prefer a structured env.PAPERLESS_SOCIALACCOUNT_PROVIDERS.valueFrom Secret reference. Do not configure both sources. |
| config.redis.existingSecret.name | string | `""` | Existing Secret containing the external broker URL. |
| config.redis.existingSecret.urlKey | string | `"url"` | Key in the existing Secret. |
| config.redis.prefix | string | `""` |  |
| config.redis.url | string | `""` | External Redis-compatible broker URL when valkey.internal is false. |
| config.secretKey.existingSecret.key | string | `"PAPERLESS_SECRET_KEY"` | Key in the existing Secret. |
| config.secretKey.existingSecret.name | string | `""` | Existing Secret containing PAPERLESS_SECRET_KEY. Empty uses a generated, upgrade-stable key. |
| config.secretRevision | int | `0` | Non-sensitive rollout revision for Secret-backed Paperless settings. Increment this when another config value changes the chart-managed Secret, a scalar env value changes, or referenced Secret contents change. Never put a credential or credential hash here. |
| config.url | string | `""` | Public Paperless URL. Empty derives the URL from the first ingress host. |
| deploymentLabels | object | `{}` | This is for setting Kubernetes Labels to a Deployment. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| env.PAPERLESS_ENABLE_FLOWER | bool | `true` | start service for monitor background jobs e.g. for prometheus (example value for env) Use a YAML boolean. False disables the process and metrics ports together. |
| env.PAPERLESS_USE_X_FORWARD_HOST | bool | `true` | correct ip-address by X-Forwarded-For (example value for env) |
| fullnameOverride | string | `""` |  |
| global.compatibility.openshift.adaptSecurityContext | string | `"auto"` | Adapt the PostgreSQL dependency security context for OpenShift SCCs. |
| global.defaultStorageClass | string | `""` | Global default StorageClass for dependency PVCs. |
| global.image.pullPolicy | string | `nil` | if set it will overwrite all pullPolicy |
| global.image.registry | string | `nil` | if set it will overwrite all registry entries |
| global.imagePullSecrets | list | `[]` | Global image pull secret names for the PostgreSQL and Valkey dependencies. |
| global.imageRegistry | string | `""` | Global registry override used by the PostgreSQL and Valkey dependencies. Use global.image.registry for the Paperless image. |
| global.security.allowInsecureImages | bool | `false` | Allow the PostgreSQL dependency to use an image outside its recognized list. |
| global.storageClass | string | `""` | Deprecated dependency StorageClass alias; use global.defaultStorageClass. |
| grafana.dashboards.annotations | object | `{}` |  |
| grafana.dashboards.enabled | bool | `false` |  |
| grafana.dashboards.labels.grafana_dashboard | string | `"1"` |  |
| image.digest | string | `"sha256:aa810a36942c63d4ee70d00eda7236cd3d6acfb7eb3f7987fb568ed14df8817a"` | Immutable multi-platform image digest. When set, it overrides the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | This sets the pull policy for images. (could be overwritten by global.image.pullPolicy) |
| image.registry | string | `"ghcr.io"` | image registry (could be overwritten by global.image.registry) |
| image.repository | string | `"paperless-ngx/paperless-ngx"` | image repository |
| image.tag | string | `""` | image tag - Overrides the image tag whose default is the chart appVersion. |
| imagePullSecrets | list | `[]` | This is for the secrets for pulling an image from a private repository more information can be found here: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/ |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| livenessProbe.enabled | bool | `true` |  |
| livenessProbe.failureThreshold | int | `6` |  |
| livenessProbe.initialDelaySeconds | int | `0` |  |
| livenessProbe.path | string | `"/"` |  |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.timeoutSeconds | int | `5` |  |
| nameOverride | string | `""` | This is to override the chart name. |
| nodeSelector | object | `{}` |  |
| persistence.accessMode | string | `"ReadWriteOnce"` |  |
| persistence.annotations | object | `{}` |  |
| persistence.enabled | bool | `true` |  |
| persistence.existingClaim | string | `nil` | A manually managed Persistent Volume and Claim Requires persistence.enabled: true If defined, PVC must be created manually before volume will be bound |
| persistence.hostPath | string | `nil` | Do not create an PVC, direct use hostPath in Pod |
| persistence.retain | bool | `true` | Retain chart-managed Paperless data when the Helm release is uninstalled. |
| persistence.size | string | `"5Gi"` |  |
| persistence.storageClass | string | `nil` | Persistent Volume Storage Class If defined, storageClassName: <storageClass> If set to "-", storageClassName: "", which disables dynamic provisioning If undefined (the default) or set to null, no storageClassName spec is   set, choosing the default provisioner.  (gp2 on AWS, standard on   GKE, AWS & OpenStack)  |
| podAnnotations | object | `{}` | This is for setting Kubernetes Annotations to a Pod. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/ |
| podLabels | object | `{}` | This is for setting Kubernetes Labels to a Pod. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| podSecurityContext | object | `{}` |  |
| postgresql.auth.database | string | `"paperless"` | Database created for Paperless by the bundled PostgreSQL dependency. |
| postgresql.auth.existingSecret | string | `""` | Existing Secret managed outside this chart. When set, it must contain the keys configured below and neither password value is used. |
| postgresql.auth.password | string | `""` | Password for the bundled Paperless database user. Empty generates a random value that Bitnami preserves from its existing Secret on upgrades. |
| postgresql.auth.postgresPassword | string | `""` | Bundled PostgreSQL administrator password. Empty generates a random, upgrade-stable value. |
| postgresql.auth.secretKeys.adminPasswordKey | string | `"postgres-password"` | Administrator password key in postgresql.auth.existingSecret. |
| postgresql.auth.secretKeys.replicationPasswordKey | string | `"replication-password"` | Replication password key in postgresql.auth.existingSecret. |
| postgresql.auth.secretKeys.userPasswordKey | string | `"password"` | Paperless database-user password key in postgresql.auth.existingSecret. |
| postgresql.auth.username | string | `"paperless"` | User created for Paperless by the bundled PostgreSQL dependency. |
| postgresql.credentialsRevision | int | `0` | Non-sensitive rollout revision for bundled PostgreSQL credentials. Increment this value whenever the effective credentials are rotated. Never put a password or password hash here. |
| postgresql.enabled | bool | `true` |  |
| postgresql.image.digest | string | `"sha256:926356130b77d5742d8ce605b258d35db9b62f2f8fd1601f9dbaef0c8a710a8d"` |  |
| postgresql.image.repository | string | `"bitnamilegacy/postgresql"` |  |
| progressDeadlineSeconds | int | `2100` | Deadline for a Deployment rollout. The default leaves five minutes of headroom beyond the 30-minute startup probe window used for migrations. |
| prometheus.rules.additionalRules | list | `[]` |  |
| prometheus.rules.enabled | bool | `false` |  |
| prometheus.rules.labels | object | `{}` |  |
| prometheus.servicemonitor.enabled | bool | `false` | Enable Flower scraping. Requires the ServiceMonitor CRD and env.PAPERLESS_ENABLE_FLOWER=true. |
| prometheus.servicemonitor.interval | string | `nil` | interval |
| prometheus.servicemonitor.labels | object | `{}` |  |
| prometheus.servicemonitor.scrapeTimeout | string | `nil` | scrape timeout |
| readinessProbe.enabled | bool | `true` |  |
| readinessProbe.failureThreshold | int | `6` |  |
| readinessProbe.initialDelaySeconds | int | `0` |  |
| readinessProbe.path | string | `"/"` |  |
| readinessProbe.periodSeconds | int | `5` |  |
| readinessProbe.timeoutSeconds | int | `3` |  |
| replicaCount | int | `1` | replicas |
| resources | object | `{}` | Container resources. HPA utilization metrics require requests.cpu for CPU (including Kubernetes' default CPU metric) and requests.memory for memory. |
| securityContext | object | `{}` |  |
| service.port | int | `80` | This sets the ports more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#field-spec-ports |
| service.type | string | `"ClusterIP"` | This sets the service type more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types |
| serviceAccount.annotations | object | `{}` | Annotations to add to the service account |
| serviceAccount.automount | bool | `false` | Automatically mount a ServiceAccount's API credentials? |
| serviceAccount.create | bool | `true` | Specifies whether a service account should be created |
| serviceAccount.name | string | `""` | The name of the service account to use. If not set and create is true, a name is generated using the fullname template |
| startupProbe.enabled | bool | `true` |  |
| startupProbe.failureThreshold | int | `180` |  |
| startupProbe.path | string | `"/"` |  |
| startupProbe.periodSeconds | int | `10` |  |
| startupProbe.timeoutSeconds | int | `5` |  |
| strategy.rollingUpdate.maxSurge | int | `0` |  |
| strategy.rollingUpdate.maxUnavailable | string | `"100%"` |  |
| strategy.type | string | `"RollingUpdate"` | Deployment strategy. Zero surge avoids creating an extra application pod. RollingUpdate is the only supported type because Helm 4 server-side apply cannot safely clear the old rollingUpdate field during a live switch to Recreate. The disruptive defaults cause downtime on every rollout. The Paperless 3 upgrade still requires the documented complete scale-to-zero and wait procedure. |
| terminationGracePeriodSeconds | int | `60` | Grace period for Paperless workers to stop cleanly. |
| tests.enabled | bool | `true` | Enable the Helm connectivity test pod. |
| tests.image.digest | string | `"sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616"` |  |
| tests.image.pullPolicy | string | `"IfNotPresent"` |  |
| tests.image.repository | string | `"busybox"` |  |
| tests.image.tag | string | `"1.38.0"` |  |
| tests.resources.limits.cpu | string | `"100m"` |  |
| tests.resources.limits.memory | string | `"32Mi"` |  |
| tests.resources.requests.cpu | string | `"10m"` |  |
| tests.resources.requests.memory | string | `"16Mi"` |  |
| tolerations | list | `[]` |  |
| valkey.auth.enabled | bool | `false` | Authentication is unsupported for the bundled broker. Disable the bundled broker and configure config.redis.existingSecret for auth. |
| valkey.dataStorage.className | string | `""` |  |
| valkey.dataStorage.keepPvc | bool | `true` |  |
| valkey.dbid | int | `0` | Database ID for non-default database |
| valkey.image.tag | string | `"9.0.5@sha256:4c64dfeae602349cd38b70ecfc631ab99624283cd975f34f96a72c6050f1b890"` |  |
| valkey.internal | bool | `true` |  |
| valkey.service.port | int | `6379` | Internal Valkey service port. The bundled chart currently requires 6379. |
| valkey.tls.enabled | bool | `false` | TLS is unsupported for the bundled broker. Disable the bundled broker and configure a rediss:// URL through config.redis.existingSecret. |
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
