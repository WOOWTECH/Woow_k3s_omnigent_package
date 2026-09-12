{{/*
Helper templates for the omnigent chart.

Resource names, selectors and pod-template labels are fixed (not derived from
the release name) on purpose: the Cloudflare tunnel and every in-cluster URL
(omnigent-server:8000, omnigent-postgres:5432) point at these exact names, and
changing a selector or a pod-template label would restart every pod. One
release per namespace is therefore the supported model.
*/}}

{{- define "omnigent.name" -}}
omnigent
{{- end -}}

{{- define "omnigent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
omnigent
{{- end -}}
{{- end -}}

{{- define "omnigent.labels" -}}
app.kubernetes.io/name: {{ include "omnigent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "omnigent.namespace" -}}
{{- if .Values.namespace.create -}}
{{ .Values.namespace.name }}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{- end -}}

{{/*
`annotations:` block carrying the keep policy, or nothing at all. Used on the
Namespace, every PVC and every chart-created Secret so `helm uninstall` cannot
delete pi-agent state, the Postgres volume or the admin credentials.
*/}}
{{- define "omnigent.keepAnnotations" -}}
{{- if .Values.keepOnUninstall -}}
annotations:
  helm.sh/resource-policy: keep
{{- end -}}
{{- end -}}

{{/* Secret names — the same in both secrets.create modes. */}}
{{- define "omnigent.adminSecretName" -}}
{{ .Values.secrets.adminSecretName }}
{{- end -}}

{{- define "omnigent.postgresSecretName" -}}
{{ .Values.secrets.postgresSecretName }}
{{- end -}}

{{/*
Postgres DATABASE_URL — kept in one place so the Secret and any consumer agree.
Only reachable with secrets.create=true; otherwise the value already lives in
the existing Secret's DATABASE_URL key.
*/}}
{{- define "omnigent.databaseUrl" -}}
postgresql+psycopg://omnigent:{{ required "postgres.password is required when secrets.create=true" .Values.postgres.password }}@omnigent-postgres:5432/omnigent
{{- end -}}

{{/*
Is this runner host enabled? Missing key means true; `enabled: false` renders
the PVC but not the Deployment.
*/}}
{{- define "omnigent.hostEnabled" -}}
{{- $host := . -}}
{{- if hasKey $host "enabled" -}}
{{- $host.enabled -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
