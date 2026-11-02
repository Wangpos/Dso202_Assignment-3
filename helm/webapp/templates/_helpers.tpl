{{/*
_helpers.tpl - named templates shared by every file in templates/.
Files whose names begin with an underscore are never rendered as objects.
*/}}

{{/* webapp.name: the chart name, or nameOverride when set. */}}
{{- define "webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
webapp.fullname: the base name of every object.
Truncated to 63 characters because Kubernetes label values and DNS labels
are limited to 63 characters. If the release name already contains the
chart name, the release name is used alone to avoid "webapp-dev-webapp".
*/}}
{{- define "webapp.fullname" -}}
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

{{/* webapp.chart: "<name>-<version>", used in the helm.sh/chart label. */}}
{{- define "webapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
webapp.selectorLabels: the labels a Service and a Deployment select on.
These must never change after the first install, because
Deployment.spec.selector is immutable.
*/}}
{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
webapp.environment: the environment name.
page.environment wins; global.environment (set by a parent chart) is the
fallback. "required" stops rendering with the given message when both are
empty, so no object can be produced without an environment.
*/}}
{{- define "webapp.environment" -}}
{{- required "page.environment must be set (dev, staging or prod)" (.Values.page.environment | default .Values.global.environment) }}
{{- end }}

{{/* webapp.labels: the full recommended label set for every object. */}}
{{- define "webapp.labels" -}}
helm.sh/chart: {{ include "webapp.chart" . }}
{{ include "webapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
dso202/environment: {{ include "webapp.environment" . | quote }}
{{- end }}
