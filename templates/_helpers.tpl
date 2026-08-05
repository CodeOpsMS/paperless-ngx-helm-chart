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
