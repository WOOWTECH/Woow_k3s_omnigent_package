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

{{/* ── LLM key proxy (#1449) ── */}}
{{- define "omnigent.llmProxy.fullname" -}}
{{- printf "%s-llm-proxy" (include "omnigent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{/* A different app.kubernetes.io/name than the server: the server's Service,
     Deployment and NetworkPolicies select name=omnigent + instance, and must never
     pick up the proxy pod. */}}
{{- define "omnigent.llmProxy.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-llm-proxy" (include "omnigent.name" .) | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "omnigent.llmProxy.labels" -}}
helm.sh/chart: {{ include "omnigent.chart" . }}
{{ include "omnigent.llmProxy.selectorLabels" . }}
app.kubernetes.io/component: llm-proxy
app.kubernetes.io/part-of: omnigent
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{/* Base URL of the proxy for one upstream ("openrouter" | "anthropic"). The headless
     Service resolves straight to the proxy pod (the operator's tunnel skips headless
     Services, so this port is never exposed). */}}
{{- define "omnigent.llmProxy.url" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v/%s" (include "omnigent.llmProxy.fullname" .ctx) .ctx.Release.Namespace .ctx.Values.llmProxy.port .upstream -}}
{{- end -}}
{{/* Real tenant keys (values only, authoritative), as JSON. */}}
{{- define "omnigent.llmKeys" -}}
{{- toJson (dict "OPENROUTER_API_KEY" (.Values.auth.openrouterApiKey | default "" | toString | trim) "ANTHROPIC_API_KEY" (.Values.auth.anthropicApiKey | default "" | toString | trim)) -}}
{{- end -}}
{{/* Per-release proxy token: the live proxy Secret's value (stable across upgrades,
     so warm runners keep working), else generated. */}}
{{- define "omnigent.llmProxy.token" -}}
{{- /* Memoised in .Values for this render: the runner env Secret, the proxy Secret and
       the host_config all call it, and a first install (no live Secret) would
       otherwise generate a different random token for each. */ -}}
{{- if not (hasKey .Values "__llmProxyToken") -}}
{{- $val := "" -}}
{{- $live := lookup "v1" "Secret" .Release.Namespace (include "omnigent.llmProxy.fullname" .) -}}
{{- if $live }}{{- with $live.data }}{{- with .proxy_token }}{{- $val = . | b64dec }}{{- end }}{{- end }}{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]{40,128}$" $val) }}{{- $val = randAlphaNum 48 }}{{- end -}}
{{- $_ := set .Values "__llmProxyToken" $val -}}
{{- end -}}
{{- index .Values "__llmProxyToken" -}}
{{- end -}}

{{/* In-cluster URL runner hosts dial back to. */}}
{{- define "omnigent.internalUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" (include "omnigent.fullname" .) .Release.Namespace .Values.service.port -}}
{{- end -}}

{{/*
Runner env (#1379) as JSON: live Secret keys (kept across upgrades) → the
platform LLM key fields (authoritative: filled sets, cleared removes) →
runner.env (explicit, wins). secret.yaml writes it; configmap.yaml derives
which sandbox providers exist from it, so both always agree.
*/}}
{{- define "omnigent.runnerEnv" -}}
{{- $env := dict "OMNIGENT_PAAS_RUNNER" "1" -}}
{{- $live := lookup "v1" "Secret" .Release.Namespace (include "omnigent.runnerEnvSecretName" .) -}}
{{- if $live }}{{- range $k, $v := ($live.data | default dict) }}{{- $_ := set $env $k ($v | b64dec) }}{{- end }}{{- end }}
{{- $managed := include "omnigent.llmKeys" . | fromJson -}}
{{- /* #1449: with the proxy, a filled key puts the per-release PROXY TOKEN into the
       runner env (same variable name), never the key itself. */ -}}
{{- $token := "" -}}
{{- if .Values.llmProxy.enabled }}{{- $token = include "omnigent.llmProxy.token" . }}{{- end -}}
{{- range $k, $v := $managed }}{{- if $v }}{{- $_ := set $env $k (default $v $token) }}{{- else }}{{- $_ := unset $env $k }}{{- end }}{{- end }}
{{- range $k, $v := .Values.runner.env }}{{- $_ := set $env $k ($v | toString) }}{{- end }}
{{- /* #1497 runner egress gate: reserved keys are always re-derived (a live leftover is
       dropped when the gate is off) and can never come from runner.env. */ -}}
{{- range $k := (list "BASH_ENV" "WOOW_EGRESS_GATE_PY" "WOOW_EGRESS_GATE_MARKER" "WOOW_EGRESS_GATE_TIMEOUT" "WOOW_EGRESS_GATE_TARGET" "WOOW_EGRESS_GATE_CONSECUTIVE") }}
  {{- if hasKey ($.Values.runner.env | default dict) $k }}{{- fail (printf "runner.env.%s is reserved for the runner egress gate (runner.egressGate)" $k) }}{{- end }}
  {{- $_ := unset $env $k }}
{{- end }}
{{- if eq (include "omnigent.runnerEgressGate" .) "true" }}
  {{- $g := .Values.runner.egressGate }}
  {{- $_ := set $env "BASH_ENV" "$([ -e \"${WOOW_EGRESS_GATE_MARKER:-/home/omnigent/.woow-egress-gate}\" ] || python3 -I -c \"$WOOW_EGRESS_GATE_PY\" >&2)" }}
  {{- $_ := set $env "WOOW_EGRESS_GATE_PY" (.Files.Get "files/runner-egress-gate.py") }}
  {{- $_ := set $env "WOOW_EGRESS_GATE_MARKER" "/home/omnigent/.woow-egress-gate" }}
  {{- $_ := set $env "WOOW_EGRESS_GATE_TIMEOUT" ($g.timeoutSeconds | int | toString) }}
  {{- with $g.target }}{{- $_ := set $env "WOOW_EGRESS_GATE_TARGET" (. | toString) }}{{- end }}
{{- end }}
{{- toJson $env -}}
{{- end -}}

{{/*
"true" when the runner egress gate (#1497) is rendered: only while runners exist AND
a runner NetworkPolicy exists — without one the probe target never gets blocked and
every runner would wait the full timeout for nothing.
*/}}
{{- define "omnigent.runnerEgressGate" -}}
{{- $g := .Values.runner.egressGate | default dict -}}
{{- if and .Values.runner.enabled $g.enabled .Values.networkPolicy.enabled .Values.networkPolicy.runner.enabled -}}
  {{- $t := int ($g.timeoutSeconds | default 0) -}}
  {{- if or (lt $t 5) (gt $t 600) }}{{- fail (printf "runner.egressGate.timeoutSeconds must be 5..600 (got %v)" $g.timeoutSeconds) }}{{- end -}}
  {{- if and $g.target (not (regexMatch "^[A-Za-z0-9.:\\[\\]-]+:[0-9]{1,5}$" ($g.target | toString))) }}{{- fail (printf "runner.egressGate.target %q must be host:port" $g.target) }}{{- end -}}
true
{{- end -}}
{{- end -}}

{{/* Comma-separated model IDs → JSON list; rejects anything that is not a plain model ID. */}}
{{- define "omnigent.modelList" -}}
{{- $out := list -}}
{{- range (splitList "," (.value | default "" | toString)) }}
  {{- $m := trim . -}}
  {{- if $m }}
    {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$" $m) }}
      {{- fail (printf "%s: %q is not a model ID (letters, digits and . _ : / - only)" $.field $m) }}
    {{- end }}
    {{- if not (has $m $out) }}{{- $out = append $out $m }}{{- end }}
  {{- end }}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
Server-side sandbox.host_config (#1379) as JSON ({} when no LLM key is set):
an OpenRouter gateway and/or an Anthropic key provider, both reading their key
from the runner env via api_key_ref (never inline), plus per-harness bindings
with a curated model_allowlist — omnigent serves that list as the managed
session's model picker (static catalog, no server-side discovery credential).
*/}}
{{- define "omnigent.hostConfig" -}}
{{- $env := include "omnigent.runnerEnv" . | fromJson -}}
{{- $or := get $env "OPENROUTER_API_KEY" -}}
{{- $an := get $env "ANTHROPIC_API_KEY" -}}
{{- $orModels := include "omnigent.modelList" (dict "value" .Values.llm.openrouterModels "field" "llm.openrouterModels") | fromJsonArray -}}
{{- $anModels := include "omnigent.modelList" (dict "value" .Values.llm.anthropicModels "field" "llm.anthropicModels") | fromJsonArray -}}
{{- $providers := dict -}}
{{- $harnesses := dict -}}
{{- /* #1449: base URLs point at the in-namespace LLM key proxy when it is on. */ -}}
{{- $orBase := "https://openrouter.ai" -}}
{{- $anBase := "https://api.anthropic.com" -}}
{{- if .Values.llmProxy.enabled }}
  {{- $orBase = include "omnigent.llmProxy.url" (dict "ctx" . "upstream" "openrouter") }}
  {{- $anBase = include "omnigent.llmProxy.url" (dict "ctx" . "upstream" "anthropic") }}
{{- end }}
{{- if and $or $orModels }}
  {{- $_ := set $providers "openrouter" (dict "kind" "gateway" "display_name" "OpenRouter"
        "openai" (dict "base_url" (printf "%s/api/v1" $orBase) "api_key_ref" "env:OPENROUTER_API_KEY" "wire_api" "chat")
        "anthropic" (dict "base_url" (printf "%s/api" $orBase) "api_key_ref" "env:OPENROUTER_API_KEY")) }}
{{- end }}
{{- if and $an $anModels }}
  {{- $_ := set $providers "anthropic" (dict "kind" "key" "display_name" "Anthropic"
        "anthropic" (dict "base_url" $anBase "api_key_ref" "env:ANTHROPIC_API_KEY")) }}
{{- end }}
{{- /* Pi: OpenRouter (any model) first, else Anthropic. */ -}}
{{- $pi := dict -}}
{{- if hasKey $providers "openrouter" }}{{- $pi = dict "provider" "openrouter" "model_allowlist" $orModels }}
{{- else if hasKey $providers "anthropic" }}{{- $pi = dict "provider" "anthropic" "model_allowlist" $anModels }}{{- end }}
{{- if $pi }}{{- $_ := set $harnesses "pi" $pi }}{{- $_ := set $harnesses "pi-native" $pi }}{{- end }}
{{- /* OpenCode requires a chat-compatible provider and an explicit default. This is
omnigent's binding, not OpenCode's own config: omnigent (0.21: resolve_bound_opencode_gateway)
writes the per-session OpenCode 2.x opencode.json from it — provider "omnigent" via
@opencode/ai/providers/openai-compatible, baseURL = openai.base_url, models = model_allowlist,
model "omnigent/<id>" (OpenCode splits a model ref at the first "/", so OpenRouter ids keep theirs).
wire_api "responses" is rejected for OpenCode, hence "chat" above. */ -}}
{{- if hasKey $providers "openrouter" }}
  {{- $_ := set $harnesses "opencode-native" (dict "provider" "openrouter" "default_model" (first $orModels) "model_allowlist" $orModels) }}
{{- end }}
{{- /* Claude Code: Anthropic first, else OpenRouter's anthropic/* models. */ -}}
{{- $claude := dict -}}
{{- if hasKey $providers "anthropic" }}{{- $claude = dict "provider" "anthropic" "model_allowlist" $anModels }}
{{- else if hasKey $providers "openrouter" }}
  {{- $orClaude := list }}{{- range $orModels }}{{- if hasPrefix "anthropic/" . }}{{- $orClaude = append $orClaude . }}{{- end }}{{- end }}
  {{- if $orClaude }}{{- $claude = dict "provider" "openrouter" "model_allowlist" $orClaude }}{{- end }}
{{- end }}
{{- if $claude }}{{- $_ := set $harnesses "claude-sdk" $claude }}{{- $_ := set $harnesses "claude-native" $claude }}{{- end }}
{{- if $providers }}
{{- toJson (dict "providers" $providers "inference" (dict "harnesses" $harnesses)) -}}
{{- else -}}
{}
{{- end -}}
{{- end -}}
