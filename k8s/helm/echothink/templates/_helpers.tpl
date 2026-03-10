{{/*
Common labels
*/}}
{{- define "echothink.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: echothink
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "echothink.selectorLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "echothink.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create a fully qualified name.
We truncate at 63 chars because some Kubernetes name fields are limited.
*/}}
{{- define "echothink.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Component-level labels helper.
Usage: {{ include "echothink.componentLabels" (dict "ctx" . "component" "postgres") }}
*/}}
{{- define "echothink.componentLabels" -}}
{{ include "echothink.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component-level selector labels helper.
*/}}
{{- define "echothink.componentSelectorLabels" -}}
{{ include "echothink.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Namespace helper
*/}}
{{- define "echothink.namespace" -}}
{{ .Values.global.namespace | default "echothink" }}
{{- end }}

{{/*
Image helper – combines image and imagePullPolicy
Usage: {{ include "echothink.image" (dict "image" .Values.postgres.image "policy" .Values.global.imagePullPolicy) }}
*/}}
{{- define "echothink.image" -}}
image: {{ .image }}
imagePullPolicy: {{ .policy | default "IfNotPresent" }}
{{- end }}

{{/*
Storage class helper
*/}}
{{- define "echothink.storageClass" -}}
{{- if .Values.global.storageClass -}}
storageClassName: {{ .Values.global.storageClass }}
{{- end -}}
{{- end }}
