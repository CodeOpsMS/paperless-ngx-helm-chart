---
title: "paperless-ngx"

description: "A document management system that transforms your physical documents into a searchable online archive so you can keep, well, less paper."

---

# paperless-ngx

![Version: 0.1.13](https://img.shields.io/badge/Version-0.1.13-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2.15.3](https://img.shields.io/badge/AppVersion-2.15.3-informational?style=flat-square)

A document management system that transforms your physical documents into a searchable online archive so you can keep, well, less paper.

**Homepage:** <https://wrenix.eu/docs/helm-charts/paperless-ngx/>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| WrenIX |  | <https://wrenix.eu> |

## Source Code

* <https://github.com/paperless-ngx/paperless-ngx>
* <https://git.chaos.fyi/wrenix/helm-charts/src/branch/main/paperless-ngx>
* <https://codeberg.org/wrenix/helm-charts/src/branch/main/paperless-ngx>

## Usage

Helm must be installed and setup to your kubernetes cluster to use the charts.
Refer to Helm's [documentation](https://helm.sh/docs) to get started.
Once Helm has been set up correctly, fetch the charts as follows:

```bash
helm pull oci://codeberg.org/wrenix/helm-charts/paperless-ngx
```

You can install a chart release using the following command:

```bash
helm install paperless-ngx-release oci://codeberg.org/wrenix/helm-charts/paperless-ngx --values values.yaml
```

To uninstall a chart release use `helm`'s delete command:

```bash
helm uninstall paperless-ngx-release
```

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| oci://docker.io/bitnamicharts | postgresql | ^16.5.6 |
| oci://docker.io/bitnamicharts | redis | 20.13.4 |

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
| config.database.host | string | `""` |  |
| config.database.name | string | `"paperless"` |  |
| config.database.pass | string | `"paperless"` |  |
| config.database.port | int | `5432` |  |
| config.database.sslmode | string | `"prefer"` |  |
| config.database.user | string | `"paperless"` |  |
| config.oidcProviders | string | `nil` |  |
| config.redis.prefix | string | `""` |  |
| config.redis.url | string | `""` |  |
| config.url | string | `nil` | default first ingress host |
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
| postgresql.auth.database | string | `"pretix"` |  |
| postgresql.auth.password | string | `"pretix"` |  |
| postgresql.auth.postgresPassword | string | `"supersecureadminpassword"` |  |
| postgresql.auth.username | string | `"pretix"` |  |
| postgresql.enabled | bool | `true` |  |
| prometheus.rules.additionalRules | list | `[]` |  |
| prometheus.rules.enabled | bool | `false` |  |
| prometheus.rules.labels | object | `{}` |  |
| prometheus.servicemonitor.enabled | bool | `false` | broken, Host need to be localhost on request (instatt of ip) needs: https://github.com/prometheus-operator/prometheus-operator/pull/7003 |
| prometheus.servicemonitor.interval | string | `nil` | interval |
| prometheus.servicemonitor.labels | object | `{}` |  |
| prometheus.servicemonitor.scrapeTimeout | string | `nil` | scrape timeout |
| readinessProbe.httpGet.path | string | `"/"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| redis.architecture | string | `"standalone"` |  |
| redis.auth.enabled | bool | `true` |  |
| redis.auth.existingSecret | string | `""` | name of an existing secret with Redis credentials (instead of auth.password), must be created ahead of time |
| redis.auth.existingSecretPasswordKey | string | `""` | Password key to be retrieved from existing secret |
| redis.auth.password | string | `"changeme"` |  |
| redis.enabled | bool | `true` |  |
| redis.global.storageClass | string | `""` |  |
| redis.master.persistence.enabled | bool | `true` |  |
| redis.replica.persistence.enabled | bool | `true` |  |
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
| volumeMounts | list | `[]` |  |
| volumes | list | `[]` |  |

Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs)
