{{/*
Chart name, truncated to 63 chars.
*/}}
{{- define "agent-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name: <release>-<chart>.
If release name already contains chart name, just use the release name.
Truncated to 63 chars.
*/}}
{{- define "agent-operator.fullname" -}}
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
Standard Kubernetes labels.
*/}}
{{- define "agent-operator.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "agent-operator.selectorLabels" . }}
{{- end }}

{{/*
Selector labels (subset used in matchLabels).
*/}}
{{- define "agent-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agent-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Webhook selector labels.
*/}}
{{- define "agent-operator.webhookSelectorLabels" -}}
app.kubernetes.io/name: {{ include "agent-operator.name" . }}-webhook
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Webhook labels.
*/}}
{{- define "agent-operator.webhookLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "agent-operator.webhookSelectorLabels" . }}
{{- end }}

{{/*
Resolved operator image (repository:tag).
*/}}
{{- define "agent-operator.operatorImage" -}}
{{- printf "%s-operator:%s" .Values.image.repository .Values.image.tag }}
{{- end }}

{{/*
Resolved webhook image (repository:tag).
*/}}
{{- define "agent-operator.webhookImage" -}}
{{- printf "%s-webhook:%s" .Values.image.repository .Values.image.tag }}
{{- end }}

{{/*
Resolved worker image.
Falls back to the operator image repository/tag when worker overrides are empty.
*/}}
{{- define "agent-operator.workerImage" -}}
{{- $repo := default .Values.image.repository .Values.worker.image.repository }}
{{- $tag  := default .Values.image.tag .Values.worker.image.tag }}
{{- printf "%s-worker:%s" $repo $tag }}
{{- end }}

{{/*
Namespace to deploy into.
*/}}
{{- define "agent-operator.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{/*
Secret name.
*/}}
{{- define "agent-operator.secretName" -}}
{{- include "agent-operator.fullname" . }}-secrets
{{- end }}

{{/*
Webhook secret name.
*/}}
{{- define "agent-operator.webhookSecretName" -}}
{{- include "agent-operator.fullname" . }}-webhook-secrets
{{- end }}

{{/*
ConfigMap name.
*/}}
{{- define "agent-operator.configMapName" -}}
{{- include "agent-operator.fullname" . }}-config
{{- end }}
