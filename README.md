---
title: "Paperless-ngx Helm Chart"

description: "A community Helm chart for deploying Paperless-ngx on Kubernetes."

---

# Paperless-ngx Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/paperless)](https://artifacthub.io/packages/helm/paperless/paperless-ngx)
[![Release](https://img.shields.io/github/v/release/CodeOpsMS/paperless-ngx-helm-chart?label=Chart%20Version)](https://github.com/CodeOpsMS/paperless-ngx-helm-chart/releases)
[![License status](https://img.shields.io/badge/license-see%20NOTICE-orange)](NOTICE)

> **This is a community-maintained Helm chart packaged by CodeOpsMS.**
> It is not an official Paperless-ngx chart and does not receive official
> support from the Paperless-ngx project.

Paperless-ngx transforms physical documents into a searchable online archive.
This chart deploys the application together with optional PostgreSQL and Valkey
dependencies on Kubernetes.

## Project links

- **Chart source:** <https://github.com/CodeOpsMS/paperless-ngx-helm-chart>
- **Paperless-ngx documentation:** <https://docs.paperless-ngx.com/>
- **Paperless-ngx source:** <https://github.com/paperless-ngx/paperless-ngx>
- **Forked from:** [WrenIX paperless-ngx Helm chart](https://codeberg.org/wrenix/helm-charts/src/branch/main/paperless-ngx)

## Maintainers

| Name | Email | URL |
|------|-------|-----|
| CodeOpsMS | <codeopsms@users.noreply.github.com> | <https://github.com/CodeOpsMS> |

## Installation

### Via the Helm repository

```bash
helm repo add paperless https://codeopsms.github.io/paperless-ngx-helm-chart/
helm repo update
helm install paperless-ngx paperless/paperless-ngx \
  --namespace paperless-ngx \
  --create-namespace
```

To install or upgrade with a custom values file:

```bash
helm upgrade --install paperless-ngx paperless/paperless-ngx \
  --namespace paperless-ngx \
  --create-namespace \
  --values my-values.yaml
```

### From source

```bash
git clone https://github.com/CodeOpsMS/paperless-ngx-helm-chart.git
cd paperless-ngx-helm-chart
helm dependency build
helm install paperless-ngx . \
  --namespace paperless-ngx \
  --create-namespace \
  --values values.yaml
```

To uninstall the release:

```bash
helm uninstall paperless-ngx --namespace paperless-ngx
```

## Artifact Hub

GitHub Pages is active and the release workflow maintains the published Helm
repository at:

```text
https://codeopsms.github.io/paperless-ngx-helm-chart/
```

The chart is available directly on
[Artifact Hub](https://artifacthub.io/packages/helm/paperless/paperless-ngx).
Its registered repository metadata is:

| Field | Value |
|-------|-------|
| Repository name | `paperless` |
| Display name | `Paperless-ngx` |
| Repository URL | `https://codeopsms.github.io/paperless-ngx-helm-chart/` |

The repository name is part of the Artifact Hub package URL and cannot be
changed after registration. The `gh-pages` branch, `index.yaml`, and Artifact
Hub metadata are checked daily by the Pages healthcheck workflow.

## Automation

Dependency discovery creates reviewable pull requests. Nothing is merged or
published automatically from an update branch.

| What | How | Interval |
|------|-----|----------|
| Paperless-ngx application | GitHub Releases check opens an app-version PR and bumps the chart version | Every 6 hours |
| PostgreSQL and Valkey charts | Renovate updates `Chart.yaml` and `Chart.lock` and bumps the chart version | Weekly |
| GitHub Actions | Dependabot opens workflow dependency PRs | Weekly |
| Helm 3 and Helm 4 CI versions | Renovate keeps each major release line current | Weekly |
| GitHub Pages Helm repository | Healthcheck verifies the published index and release asset | Daily |

To activate all update sources, install the
[Renovate GitHub App](https://github.com/apps/renovate) for this repository and
keep **Settings → Actions → General → Allow GitHub Actions to create and
approve pull requests** enabled. Renovate and Dependabot are configured to
create PRs only; updates remain subject to the normal Helm CI review gate.

## Requirements

| Repository | Name | Version source |
|------------|------|----------------|
| https://valkey.io/valkey-helm/ | valkey | [Chart.yaml](Chart.yaml) |
| oci://docker.io/bitnamicharts | postgresql | [Chart.yaml](Chart.yaml) |

## License and provenance

The combined chart does not currently have a confirmed overall license. The
imported WrenIX source and history still contain no license grant, so this
package must not be represented as entirely MIT licensed. Original CodeOpsMS
contributions are offered separately under the
[MIT terms for CodeOpsMS contributions](LICENSES/CodeOpsMS-MIT.txt); those
terms do not relicense the imported material.

Read [NOTICE](NOTICE) for the checked upstream commit, provenance, exact scope,
and the evidence still required to establish redistribution rights. Artifact
Hub intentionally receives no package-wide license identifier while that
status remains unresolved.

Paperless-ngx itself is a separate project licensed under GPL-3.0.

## Values

### NetworkPolicy

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| networkPolicy.egress.database | list | `[]` | rule to access Database (e.g. postgresql, redis) |
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
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| config.apps | string | `nil` |  |
| config.database.engine | string | `"postgresql"` |  |
| config.database.existingSecret.name | string | `""` | if set it use external secret for connect to database |
| config.database.existingSecret.passKey | string | `"password"` | configurate key of secret where the password of database use is set |
| config.database.host | string | `""` |  |
| config.database.name | string | `"paperless"` |  |
| config.database.pass | string | `"paperless"` | password to access database (has no effect if existingSecret.name is set) |
| config.database.port | int | `5432` |  |
| config.database.sslmode | string | `"prefer"` |  |
| config.database.user | string | `"paperless"` |  |
| config.oidcProviders | string | `nil` |  |
| config.redis.prefix | string | `""` |  |
| config.redis.url | string | `""` |  |
| config.url | string | `nil` | default first ingress host |
| deploymentLabels | object | `{}` | This is for setting Kubernetes Labels to a Deployment. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| env.PAPERLESS_ENABLE_FLOWER | bool | `true` | start service for monitor background jobs e.g. for prometheus (example value for env) |
| env.PAPERLESS_USE_X_FORWARD_HOST | bool | `true` | correct ip-address by X-Forwarded-For (example value for env) |
| fullnameOverride | string | `""` |  |
| global.image.pullPolicy | string | `nil` | if set it will overwrite all pullPolicy |
| global.image.registry | string | `nil` | if set it will overwrite all registry entries |
| grafana.dashboards.annotations | object | `{}` |  |
| grafana.dashboards.enabled | bool | `false` |  |
| grafana.dashboards.labels.grafana_dashboard | string | `"1"` |  |
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
| livenessProbe.httpGet.path | string | `"/"` |  |
| livenessProbe.httpGet.port | string | `"http"` |  |
| nameOverride | string | `""` | This is to override the chart name. |
| nodeSelector | object | `{}` |  |
| persistence.accessMode | string | `"ReadWriteOnce"` |  |
| persistence.annotations | object | `{}` |  |
| persistence.enabled | bool | `true` |  |
| persistence.existingClaim | string | `nil` | A manually managed Persistent Volume and Claim Requires persistence.enabled: true If defined, PVC must be created manually before volume will be bound |
| persistence.hostPath | string | `nil` | Do not create an PVC, direct use hostPath in Pod |
| persistence.size | string | `"5Gi"` |  |
| persistence.storageClass | string | `nil` | Persistent Volume Storage Class If defined, storageClassName: <storageClass> If set to "-", storageClassName: "", which disables dynamic provisioning If undefined (the default) or set to null, no storageClassName spec is   set, choosing the default provisioner.  (gp2 on AWS, standard on   GKE, AWS & OpenStack)  |
| podAnnotations | object | `{}` | This is for setting Kubernetes Annotations to a Pod. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/ |
| podLabels | object | `{}` | This is for setting Kubernetes Labels to a Pod. For more information checkout: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| podSecurityContext | object | `{}` |  |
| postgresql.auth.database | string | `"paperless"` |  |
| postgresql.auth.password | string | `"paperless"` |  |
| postgresql.auth.postgresPassword | string | `"supersecureadminpassword"` |  |
| postgresql.auth.username | string | `"paperless"` |  |
| postgresql.enabled | bool | `true` |  |
| postgresql.image.repository | string | `"bitnamilegacy/postgresql"` |  |
| prometheus.rules.additionalRules | list | `[]` |  |
| prometheus.rules.enabled | bool | `false` |  |
| prometheus.rules.labels | object | `{}` |  |
| prometheus.servicemonitor.enabled | bool | `false` | broken, Host need to be localhost on request (instatt of ip) needs: https://github.com/prometheus-operator/prometheus-operator/pull/7003 |
| prometheus.servicemonitor.interval | string | `nil` | interval |
| prometheus.servicemonitor.labels | object | `{}` |  |
| prometheus.servicemonitor.scrapeTimeout | string | `nil` | scrape timeout |
| readinessProbe.httpGet.path | string | `"/"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| replicaCount | int | `1` | replicas |
| resources | object | `{}` |  |
| securityContext | object | `{}` |  |
| service.port | int | `80` | This sets the ports more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#field-spec-ports |
| service.type | string | `"ClusterIP"` | This sets the service type more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types |
| serviceAccount.annotations | object | `{}` | Annotations to add to the service account |
| serviceAccount.automount | bool | `true` | Automatically mount a ServiceAccount's API credentials? |
| serviceAccount.create | bool | `true` | Specifies whether a service account should be created |
| serviceAccount.name | string | `""` | The name of the service account to use. If not set and create is true, a name is generated using the fullname template |
| tolerations | list | `[]` |  |
| valkey.dataStorage.className | string | `""` |  |
| valkey.dataStorage.keepPvc | bool | `true` |  |
| valkey.dbid | int | `0` | Database ID for non-default database |
| valkey.internal | bool | `true` |  |
| valkey.service.port | int | `6379` |  |
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |

Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs)
