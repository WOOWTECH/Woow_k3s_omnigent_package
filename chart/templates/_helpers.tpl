{{/* omnigent helpers. Deployed per-tenant by paas-operator as svc-{ref[:8]} into paas-ws-*. */}}
{{- define "omnigent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{/* The un-suffixed fullname is the ENTRANCE Service: the operator routes the
     tunnel to the first non-headless Service of the release. */}}
{{- define "omnigent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- define "omnigent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "omnigent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "omnigent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "omnigent.labels" -}}
helm.sh/chart: {{ include "omnigent.chart" . }}
{{ include "omnigent.selectorLabels" . }}
app.kubernetes.io/component: server
app.kubernetes.io/part-of: omnigent
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}
{{- define "omnigent.serverServiceAccountName" -}}
{{- printf "%s-server" (include "omnigent.fullname" .) -}}
{{- end -}}
{{- define "omnigent.runnerServiceAccountName" -}}
{{- printf "%s-runner" (include "omnigent.fullname" .) -}}
{{- end -}}
{{/* Secret carrying admin_password + cookie_secret — auth.existingSecret wins. */}}
{{- define "omnigent.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "omnigent.fullname" .) -}}
{{- end -}}
{{- end -}}
{{/* Secret projected into every runner Pod via envFrom (provider keys). */}}
{{- define "omnigent.runnerEnvSecretName" -}}
{{- printf "%s-runner-env" (include "omnigent.fullname" .) -}}
{{- end -}}
{{- define "omnigent.pvcName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "omnigent.fullname" .) -}}
{{- end -}}
{{- end -}}
{{- define "omnigent.configMapName" -}}
{{- printf "%s-config" (include "omnigent.fullname" .) -}}
{{- end -}}
{{/* explicit value wins; else the live Secret's value (stable across upgrades); else generate. */}}
{{- define "omnigent.resolveSecretValue" -}}
{{- $ctx := .ctx -}}
{{- $val := .explicit -}}
{{- if not $val -}}
  {{- $live := lookup "v1" "Secret" $ctx.Release.Namespace (include "omnigent.secretName" $ctx) -}}
  {{- if $live -}}
    {{- with $live.data -}}
      {{- with (index . $.key) -}}
        {{- $val = . | b64dec -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- /* hex keys (cookie_secret) must be 64 hex chars: omnigent refuses to start
       otherwise — a malformed live value is regenerated rather than reused. */ -}}
{{- if and $.hex $val (not (regexMatch "^[0-9a-fA-F]{64}$" $val)) -}}
  {{- $val = "" -}}
{{- end -}}
{{- if not $val -}}
  {{- if $.hex -}}
    {{- $val = randAlphaNum 64 | sha256sum -}}
  {{- else -}}
    {{- $val = randAlphaNum (default 24 $.length | int) -}}
  {{- end -}}
{{- end -}}
{{- $val -}}
{{- end -}}

{{/*
Admin username. omnigent has no rename API (username is the account key), so
this only matters on first boot; validated so a bad value fails the render
instead of creating an account nobody can type.
*/}}
{{- define "omnigent.adminUsername" -}}
{{- $u := .Values.admin.username | toString -}}
{{- if not (regexMatch "^[A-Za-z0-9._@-]{1,64}$" $u) -}}
{{- fail (printf "admin.username %q is invalid: 1-64 characters from A-Z a-z 0-9 . _ @ -" $u) -}}
{{- end -}}
{{- $u -}}
{{- end -}}

{{/* In-cluster URL runner hosts dial back to. */}}
{{- define "omnigent.internalUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" (include "omnigent.fullname" .) .Release.Namespace .Values.service.port -}}
{{- end -}}
