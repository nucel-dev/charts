{{/*
Chart name truncated to 63 chars.
*/}}
{{- define "nucel.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name: release + chart.
*/}}
{{- define "nucel.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard Kubernetes labels.
*/}}
{{- define "nucel.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "nucel.selectorLabels" . }}
{{- end }}

{{/*
Selector labels for nucel-server.
*/}}
{{- define "nucel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nucel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
SurrealDB selector labels.
*/}}
{{- define "nucel.surrealdbLabels" -}}
app.kubernetes.io/name: surrealdb
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Deployment namespace.
*/}}
{{- define "nucel.namespace" -}}
{{- .Values.namespace.name | default "nucel" }}
{{- end }}

{{/*
Secret name.
*/}}
{{- define "nucel.secretName" -}}
{{- include "nucel.fullname" . }}-secrets
{{- end }}

{{/*
ConfigMap name.
*/}}
{{- define "nucel.configMapName" -}}
{{- include "nucel.fullname" . }}-config
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "nucel.serviceAccountName" -}}
{{- include "nucel.fullname" . }}
{{- end }}
