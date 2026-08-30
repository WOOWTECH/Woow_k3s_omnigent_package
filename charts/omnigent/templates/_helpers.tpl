{{/*
Standard Helm helper templates for the omnigent chart.
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
Postgres DATABASE_URL — kept in one place so server + Job + smoke test agree.
*/}}
{{- define "omnigent.databaseUrl" -}}
postgresql+psycopg://omnigent:{{ .Values.postgres.password }}@omnigent-postgres:5432/omnigent
{{- end -}}
