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
{{- if and .Values.serviceAccount .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "nucel.fullname" . -}}
{{- end -}}
{{- end }}

{{/*
nucel.podSecurityContext — pod-level securityContext for the server /
worker / worker-pool Deployments. Renders nothing when the value is empty.
Usage: {{- include "nucel.podSecurityContext" . | nindent 6 }}
*/}}
{{- define "nucel.podSecurityContext" -}}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
nucel.containerSecurityContext — container-level securityContext. Renders
nothing when the value is empty.
Usage: {{- include "nucel.containerSecurityContext" . | nindent 10 }}
*/}}
{{- define "nucel.containerSecurityContext" -}}
{{- with .Values.containerSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
nucel.surrealdbContainerSecurityContext — container-level securityContext
for the in-chart SurrealDB container (audit #22). The StatefulSet's
pod-level securityContext (runAsNonRoot 1000) is inlined in the template;
this adds the container restricted profile. Renders nothing when empty.
Usage: {{- include "nucel.surrealdbContainerSecurityContext" . | nindent 10 }}
*/}}
{{- define "nucel.surrealdbContainerSecurityContext" -}}
{{- with (default (dict) .Values.surrealdb.containerSecurityContext) }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
─────────────────────────────────────────────────────────────────────────────
Storage strategy helpers (#236 / #244).

The `storage.classes.<class>` block lets operators pick a backend per data
class: `s3` (object storage, shared across replicas), `pvc` (a
PersistentVolumeClaim) or `emptyDir` (ephemeral, single-replica only).

Two classes (`pages`, `repos`) are S3-capable in the nucel-server binary
today; the rest are filesystem-only, so `s3` is rejected for them with a
`fail` so an operator can't silently configure a no-op backend.
─────────────────────────────────────────────────────────────────────────────
*/}}

{{/*
nucel.storage.backend — resolve the effective backend for a data class.
Usage: include "nucel.storage.backend" (dict "ctx" $ "class" "registry")
Falls back to the class default when `storage.classes.<class>.backend` is
unset.
*/}}
{{- define "nucel.storage.backend" -}}
{{- $ctx := .ctx -}}
{{- $class := .class -}}
{{- $defaults := dict "pages" "emptyDir" "repos" "pvc" "registry" "pvc" "npm" "pvc" "artifacts" "pvc" "gitWorkspaces" "pvc" "logs" "pvc" "workspaces" "emptyDir" -}}
{{- $classes := default (dict) (default (dict) $ctx.Values.storage).classes -}}
{{- $cfg := default (dict) (index $classes $class) -}}
{{- default (index $defaults $class) $cfg.backend -}}
{{- end -}}

{{/*
nucel.storage.s3Capable — true if the binary supports an S3 backend for
this class. Only `pages` and `repos` qualify today.
*/}}
{{- define "nucel.storage.s3Capable" -}}
{{- $class := .class -}}
{{- if or (eq $class "pages") (eq $class "repos") (eq $class "gitWorkspaces") -}}
true
{{- end -}}
{{- end -}}

{{/*
nucel.storage.validate — fail-fast guards run from NOTES + at least one
template so a misconfiguration aborts `helm install/upgrade` rather than
deploying a broken topology:
  1. backend=s3 on a filesystem-only class is rejected.
  2. backend=emptyDir or a ReadWriteOnce PVC with server.replicas > 1
     (and no HPA) is rejected for any class that must be shared across
     replicas — that's the Multi-Attach / 404-race bug (#244) this change
     fixes. RWX access modes are allowed with multiple replicas.
*/}}
{{- define "nucel.storage.validate" -}}
{{- $ctx := . -}}
{{- $classes := default (dict) (default (dict) $ctx.Values.storage).classes -}}
{{- $replicas := int (default 1 $ctx.Values.server.replicas) -}}
{{- $hpaOn := or (and $ctx.Values.hpa $ctx.Values.hpa.enabled) (and $ctx.Values.autoscaling $ctx.Values.autoscaling.enabled) -}}
{{- $multi := or (gt $replicas 1) $hpaOn -}}
{{- /* Classes whose data MUST be visible to every server replica. The
       `gitWorkspaces` (repos) hot-cache PVC is included: with replicas > 1
       the server pods + the worker all mount /data/repos, which a RWO volume
       cannot satisfy (Multi-Attach). backend=s3 layers a cold tier on top but
       the local PVC must still be RWX for multi-replica.

       We iterate the canonical list (not just explicitly-configured classes)
       so an install that scales server.replicas > 1 WITHOUT touching
       storage.classes still trips the guard on the legacy RWO PVC defaults
       — the exact #244 regression this change closes. */ -}}
{{- $sharedClasses := list "pages" "registry" "npm" "artifacts" "gitWorkspaces" -}}
{{- $allClasses := list "pages" "registry" "npm" "artifacts" "gitWorkspaces" "workspaces" -}}
{{- range $class := $allClasses -}}
{{- $cfg := default (dict) (index $classes $class) -}}
{{- $backend := include "nucel.storage.backend" (dict "ctx" $ctx "class" $class) -}}
{{- if eq $backend "s3" -}}
{{- if not (include "nucel.storage.s3Capable" (dict "class" $class)) -}}
{{- fail (printf "storage.classes.%s.backend=s3 is not supported: the nucel-server binary only speaks S3 for 'pages' and 'repos'/'gitWorkspaces'. Use backend=pvc (RWX for multi-replica) for %s." $class $class) -}}
{{- end -}}
{{- end -}}
{{- if and $multi (has $class $sharedClasses) -}}
{{- if eq $backend "emptyDir" -}}
{{- fail (printf "storage.classes.%s.backend=emptyDir cannot be shared across %d replicas (HPA: %t) — each pod gets its own empty volume, causing the data-loss / 404-race in #244. Use backend=s3 (pages) or a ReadWriteMany PVC." $class $replicas $hpaOn) -}}
{{- end -}}
{{- /* A PVC is rendered for this class when backend=pvc, OR for
       gitWorkspaces always (the s3 backend keeps the local PVC as a hot
       cache). In both cases a ReadWriteOnce PVC can't multi-attach. */ -}}
{{- $rendersPvc := or (eq $backend "pvc") (and (eq $class "gitWorkspaces") (eq $backend "s3")) -}}
{{- if $rendersPvc -}}
{{- $access := default "ReadWriteOnce" $cfg.accessMode -}}
{{- if eq $access "ReadWriteOnce" -}}
{{- fail (printf "storage.classes.%s: a ReadWriteOnce PVC cannot attach to %d replicas (HPA: %t) — this is the Multi-Attach error in #244. Set storage.classes.%s.accessMode=ReadWriteMany (EFS/NFS/CephFS) or pin server.replicas=1." $class $replicas $hpaOn $class) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
nucel.storage.pvcName — the PVC object name for a data class.
*/}}
{{- define "nucel.storage.pvcName" -}}
{{- $names := dict "repos" "nucel-repos" "gitWorkspaces" "nucel-repos" "artifacts" "nucel-ci-data" "registry" "nucel-registry" "npm" "nucel-npm" "pages" "nucel-pages" "logs" "nucel-ci-data" -}}
{{- index $names .class -}}
{{- end -}}
