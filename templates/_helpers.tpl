{{/*
Expand the name of the chart.
*/}}
{{- define "paperless-ngx.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Build the Paperless-ngx image reference. An immutable digest takes precedence
over the mutable tag while retaining the configured registry and repository.
*/}}
{{- define "paperless-ngx.image" -}}
{{- $registry := coalesce .Values.global.image.registry .Values.image.registry -}}
{{- $repository := printf "%s/%s" $registry .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/* Build the immutable Helm test image reference. */}}
{{- define "paperless-ngx.testImage" -}}
{{- if .Values.tests.image.digest -}}
{{- printf "%s:%s@%s" .Values.tests.image.repository .Values.tests.image.tag .Values.tests.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.tests.image.repository .Values.tests.image.tag -}}
{{- end -}}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "paperless-ngx.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Build the PostgreSQL chart fullname before the primary service suffix. */}}
{{- define "paperless-ngx.postgresqlBaseFullname" -}}
{{- $globalOverride := dig "global" "postgresql" "fullnameOverride" "" .Values.postgresql -}}
{{- $fullname := "" -}}
{{- if $globalOverride -}}
{{- $fullname = $globalOverride | trunc 63 | trimSuffix "-" -}}
{{- else if .Values.postgresql.fullnameOverride -}}
{{- $fullname = .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "postgresql" .Values.postgresql.nameOverride -}}
{{- $releaseName := regexReplaceAll "(-?[^a-z\\d\\-])+-?" (lower .Release.Name) "-" -}}
{{- if contains $name $releaseName -}}
{{- $fullname = $releaseName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $fullname = printf "%s-%s" $releaseName $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- $fullname -}}
{{- end }}

{{/*
Build the PostgreSQL primary service name with the same rules as the bundled
Bitnami dependency. The dependency is scoped to the Helm release, not to the
Paperless chart fullname.
*/}}
{{- define "paperless-ngx.postgresqlFullname" -}}
{{- $fullname := include "paperless-ngx.postgresqlBaseFullname" . -}}
{{- if eq (default "standalone" .Values.postgresql.architecture) "replication" -}}
{{- printf "%s-%s" $fullname (dig "primary" "name" "primary" .Values.postgresql) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $fullname -}}
{{- end -}}
{{- end }}

{{/* Build the PostgreSQL app.kubernetes.io/name selector label. */}}
{{- define "paperless-ngx.postgresqlName" -}}
{{- default "postgresql" .Values.postgresql.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Resolve the effective Bitnami PostgreSQL application username. */}}
{{- define "paperless-ngx.postgresqlUsername" -}}
{{- coalesce (dig "global" "postgresql" "auth" "username" "" .Values.postgresql) .Values.postgresql.auth.username "postgres" -}}
{{- end }}

{{/* Resolve the effective Bitnami PostgreSQL application database. */}}
{{- define "paperless-ngx.postgresqlDatabase" -}}
{{- tpl ((coalesce (dig "global" "postgresql" "auth" "database" "" .Values.postgresql) .Values.postgresql.auth.database "postgres") | toString) . -}}
{{- end }}

{{/* Resolve the Secret used by the Bitnami PostgreSQL application user. */}}
{{- define "paperless-ngx.postgresqlSecretName" -}}
{{- $existing := coalesce (dig "global" "postgresql" "auth" "existingSecret" "" .Values.postgresql) .Values.postgresql.auth.existingSecret -}}
{{- if $existing -}}
{{- tpl ($existing | toString) . -}}
{{- else -}}
{{- include "paperless-ngx.postgresqlBaseFullname" . -}}
{{- end -}}
{{- end }}

{{/* Resolve the Bitnami PostgreSQL administrator password key. */}}
{{- define "paperless-ngx.postgresqlAdminPasswordKey" -}}
{{- $existing := coalesce (dig "global" "postgresql" "auth" "existingSecret" "" .Values.postgresql) .Values.postgresql.auth.existingSecret -}}
{{- if $existing -}}
{{- $globalKey := dig "global" "postgresql" "auth" "secretKeys" "adminPasswordKey" "" .Values.postgresql -}}
{{- if $globalKey -}}
{{- tpl ($globalKey | toString) . -}}
{{- else if .Values.postgresql.auth.secretKeys.adminPasswordKey -}}
{{- tpl (.Values.postgresql.auth.secretKeys.adminPasswordKey | toString) . -}}
{{- end -}}
{{- else -}}
postgres-password
{{- end -}}
{{- end }}

{{/* Resolve the Secret key used by the Bitnami PostgreSQL application user. */}}
{{- define "paperless-ngx.postgresqlUserPasswordKey" -}}
{{- $existing := coalesce (dig "global" "postgresql" "auth" "existingSecret" "" .Values.postgresql) .Values.postgresql.auth.existingSecret -}}
{{- $username := include "paperless-ngx.postgresqlUsername" . -}}
{{- if or (empty $username) (eq $username "postgres") -}}
{{- include "paperless-ngx.postgresqlAdminPasswordKey" . -}}
{{- else -}}
{{- if $existing -}}
{{- $globalKey := dig "global" "postgresql" "auth" "secretKeys" "userPasswordKey" "" .Values.postgresql -}}
{{- if $globalKey -}}
{{- tpl ($globalKey | toString) . -}}
{{- else if .Values.postgresql.auth.secretKeys.userPasswordKey -}}
{{- tpl (.Values.postgresql.auth.secretKeys.userPasswordKey | toString) . -}}
{{- end -}}
{{- else -}}
password
{{- end -}}
{{- end -}}
{{- end }}

{{/* Resolve the Bitnami PostgreSQL replication password key. */}}
{{- define "paperless-ngx.postgresqlReplicationPasswordKey" -}}
{{- $existing := coalesce (dig "global" "postgresql" "auth" "existingSecret" "" .Values.postgresql) .Values.postgresql.auth.existingSecret -}}
{{- if $existing -}}
{{- $globalKey := dig "global" "postgresql" "auth" "secretKeys" "replicationPasswordKey" "" .Values.postgresql -}}
{{- if $globalKey -}}
{{- tpl ($globalKey | toString) . -}}
{{- else if .Values.postgresql.auth.secretKeys.replicationPasswordKey -}}
{{- tpl (.Values.postgresql.auth.secretKeys.replicationPasswordKey | toString) . -}}
{{- else -}}
replication-password
{{- end -}}
{{- else -}}
replication-password
{{- end -}}
{{- end }}

{{/* Resolve the effective PostgreSQL service port. */}}
{{- define "paperless-ngx.postgresqlServicePort" -}}
{{- coalesce (dig "global" "postgresql" "service" "ports" "postgresql" "" .Values.postgresql) (dig "primary" "service" "ports" "postgresql" 5432 .Values.postgresql) -}}
{{- end }}

{{/* Resolve the PostgreSQL container port selected by NetworkPolicy. */}}
{{- define "paperless-ngx.postgresqlContainerPort" -}}
{{- dig "containerPorts" "postgresql" 5432 .Values.postgresql -}}
{{- end }}

{{/* Hash only effective connection metadata, never PostgreSQL password values. */}}
{{- define "paperless-ngx.postgresqlConnectionChecksum" -}}
{{- printf "%t|%s|%s|%s|%s|%s|%d" .Values.postgresql.enabled (include "paperless-ngx.postgresqlFullname" .) (include "paperless-ngx.postgresqlServicePort" .) (include "paperless-ngx.postgresqlDatabase" .) (include "paperless-ngx.postgresqlUsername" .) (printf "%s/%s" (include "paperless-ngx.postgresqlSecretName" .) (include "paperless-ngx.postgresqlUserPasswordKey" .)) (int .Values.postgresql.credentialsRevision) | sha256sum -}}
{{- end }}

{{/* Build the Valkey service name with the bundled dependency's rules. */}}
{{- define "paperless-ngx.valkeyFullname" -}}
{{- if .Values.valkey.fullnameOverride -}}
{{- .Values.valkey.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "valkey" .Values.valkey.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Build the Valkey app.kubernetes.io/name selector label. */}}
{{- define "paperless-ngx.valkeyName" -}}
{{- default "valkey" .Values.valkey.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Hash only effective connection metadata, never dependency Secret values. */}}
{{- define "paperless-ngx.valkeyConnectionChecksum" -}}
{{- printf "%t|%s|%d|%d" .Values.valkey.internal (include "paperless-ngx.valkeyFullname" .) (int .Values.valkey.service.port) (int .Values.valkey.dbid) | sha256sum -}}
{{- end }}

{{/* Fail closed for dependency settings the parent chart cannot connect to. */}}
{{- define "paperless-ngx.validateDependencies" -}}
{{- if .Values.postgresql.namespaceOverride -}}
{{- fail "postgresql.namespaceOverride is unsupported because Paperless and the bundled PostgreSQL Secret must be in the same namespace" -}}
{{- end -}}
{{- if and .Values.valkey.internal (dig "auth" "enabled" false .Values.valkey) -}}
{{- fail "valkey.auth.enabled is unsupported for the bundled broker; use an external authenticated broker through config.redis.existingSecret" -}}
{{- end -}}
{{- if and .Values.valkey.internal (dig "tls" "enabled" false .Values.valkey) -}}
{{- fail "valkey.tls.enabled is unsupported for the bundled broker; use an external TLS broker URL through config.redis.existingSecret" -}}
{{- end -}}
{{- $existing := coalesce (dig "global" "postgresql" "auth" "existingSecret" "" .Values.postgresql) .Values.postgresql.auth.existingSecret -}}
{{- if $existing -}}
{{- if empty (include "paperless-ngx.postgresqlAdminPasswordKey" .) -}}
{{- fail "the effective PostgreSQL existing Secret administrator password key must not be empty" -}}
{{- end -}}
{{- $username := include "paperless-ngx.postgresqlUsername" . -}}
{{- if and (not (or (empty $username) (eq $username "postgres"))) (empty (include "paperless-ngx.postgresqlUserPasswordKey" .)) -}}
{{- fail "the effective PostgreSQL existing Secret user password key must not be empty" -}}
{{- end -}}
{{- if and (eq (default "standalone" .Values.postgresql.architecture) "replication") (empty (include "paperless-ngx.postgresqlReplicationPasswordKey" .)) -}}
{{- fail "the effective PostgreSQL existing Secret replication password key must not be empty" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "paperless-ngx.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "paperless-ngx.labels" -}}
helm.sh/chart: {{ include "paperless-ngx.chart" . }}
{{ include "paperless-ngx.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "paperless-ngx.selectorLabels" -}}
app.kubernetes.io/name: {{ include "paperless-ngx.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "paperless-ngx.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "paperless-ngx.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
