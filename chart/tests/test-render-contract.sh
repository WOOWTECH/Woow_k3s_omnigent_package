#!/usr/bin/env bash
# omnigent render contract: the server itself is the single exposed port (no
# auth-proxy — omnigent has its own accounts login); the first admin is created
# AT BOOT from the platform-pinned admin_password (closes the open /auth/setup
# window); SQLite on one RWO PVC; runner Jobs via the upstream kubernetes
# sandbox provider with a namespaced, exec-less Role; release-prefixed names so
# several instances share one namespace; non-root; no hard-coded namespace.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (render-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (render-contract): $1"; exit 1; }
OUT="$($HELM template svc-aaaa1111 "$CHART_DIR" -n SENTINEL)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment")')"
env_of() { printf '%s' "$DEP" | yq ".spec.template.spec.containers[0].env[] | select(.name==\"$1\") | $2"; }

# single ClusterIP :8000 named after the release (the operator's tunnel target)
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l)" = "1" ] || fail "expected exactly one Service (no LLM key → no proxy Service)"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name')" = "svc-aaaa1111-omnigent" ] || fail "entrance Service must be the un-suffixed fullname"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.type')" = "ClusterIP" ] || fail "Service is not ClusterIP"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.ports[0].targetPort')" = "8000" ] || fail "Service targetPort != 8000"
printf '%s' "$OUT" | grep -qiE 'cloudflared|pgbouncer|postgres|nginx' && fail "cloudflared/postgres/pgbouncer/nginx must not be rendered"
# server + the runner-gc sidecar (#1349) only — no auth-proxy
[ "$(printf '%s' "$DEP" | yq '[.spec.template.spec.containers[].name] | join(",")')" = "server,runner-gc" ] || fail "server pod must be exactly server + runner-gc (no auth-proxy sidecar)"

# Reviewed source digest; this render assertion does not prove JCR availability.
[ "$(yq '.version' "$CHART_DIR/Chart.yaml")" = "0.1.20" ] || fail "native MCP chart version must be 0.1.20"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="server") | .image')" = "jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes:20261121.1104@sha256:ca7d431c241388f7ed7ae4db6b7583bd3952f303a68a53467985d5a1f33539e5" ] || fail "server must use the reviewed Kubernetes candidate digest"
[ "$(yq '.runner.image' "$CHART_DIR/values.yaml")" = "jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host:20261111.0647@sha256:701101d009847e7dfb2c607314d42a38d171c9c44732c0e2a624177e02ce23bb" ] || fail "native MCP upgrade must retain the released runner pin"

# Native MCP base is complete and independent of the accounts/UI base.
[ -z "$(env_of OMNIGENT_MCP_PUBLIC_BASE_URL .value)" ] || fail "unset MCP base must delegate to the server fallback"
MCP="$($HELM template t "$CHART_DIR" --set-string server.baseUrl=https://ui.example.test --set-string mcp.publicBaseUrl=https://mcp.example.test/deploy/prefix/)"
MCP_ENV="$(printf '%s' "$MCP" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="server") | .env')"
[ "$(printf '%s' "$MCP_ENV" | yq '.[] | select(.name=="OMNIGENT_MCP_PUBLIC_BASE_URL") | .value')" = "https://mcp.example.test/deploy/prefix/" ] || fail "complete MCP base must be passed unchanged"
[ "$(printf '%s' "$MCP_ENV" | yq '.[] | select(.name=="OMNIGENT_ACCOUNTS_BASE_URL") | .value')" = "https://ui.example.test" ] || fail "MCP base must not replace accounts base"
[ "$(printf '%s' "$MCP" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l)" = "1" ] || fail "native MCP must use the existing Service"
[ "$($HELM template t "$CHART_DIR" --set runner.enabled=false --set-string mcp.publicBaseUrl=http://localhost:8000/prefix | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="OMNIGENT_MCP_PUBLIC_BASE_URL") | .value')" = "http://localhost:8000/prefix" ] || fail "loopback development / disabled runners must preserve the MCP base"
if $HELM template t "$CHART_DIR" --set-string 'server.extraEnv[0].name=OMNIGENT_MCP_PUBLIC_BASE_URL' --set-string 'server.extraEnv[0].value=https://other.example.test' >/dev/null 2>&1; then
  fail "MCP base must have one configuration source (mcp.publicBaseUrl)"
fi

# auth: accounts provider, boot-time admin from the Secret, sharing off
[ "$(env_of OMNIGENT_AUTH_PROVIDER .value)" = "accounts" ] || fail "OMNIGENT_AUTH_PROVIDER must be accounts"
[ "$(env_of OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD .valueFrom.secretKeyRef.key)" = "admin_password" ] || fail "INIT_ADMIN_PASSWORD must come from Secret admin_password"
[ "$(env_of OMNIGENT_ACCOUNTS_COOKIE_SECRET .valueFrom.secretKeyRef.key)" = "cookie_secret" ] || fail "cookie secret must come from the Secret"
[ "$(env_of OMNIGENT_PUBLIC_SHARING .value)" = "0" ] || fail "public sharing must default off"
[ "$(env_of OMNIGENT_PUBLIC_API_DOCS .value)" = "0" ] || fail "public API docs must default off"
[ "$(env_of OMNIGENT_PUBLIC_HSTS .value)" = "1" ] || fail "HSTS must be on for tenant URLs"
[ "$($HELM template t "$CHART_DIR" --set server.publicApiDocs=true | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="OMNIGENT_PUBLIC_API_DOCS") | .value')" = "1" ] || fail "server.publicApiDocs=true must render 1"
if $HELM template t "$CHART_DIR" --set-string 'server.extraEnv[0].name=OMNIGENT_PUBLIC_HSTS' --set-string 'server.extraEnv[0].value=0' >/dev/null 2>&1; then
  fail "server.extraEnv must not be able to disable HSTS"
fi
# #328 (0.1.19): omnigent 0.21 turns session_orchestration on by default; the chart keeps 0.20's
# behaviour by appending -session_orchestration unless server.sessionOrchestration=true.
features_of() { $HELM template t "$CHART_DIR" "$@" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="OMNIGENT_FEATURES") | .value'; }
[ "$(env_of OMNIGENT_FEATURES .value)" = "-session_orchestration" ] || fail "session_orchestration must default off"
[ "$(features_of --set-string 'server.features=usage_page\,harness_install')" = "usage_page,harness_install,-session_orchestration" ] || fail "server.features must keep its names and still disable session_orchestration"
[ -z "$(features_of --set server.sessionOrchestration=true)" ] || fail "sessionOrchestration=true with no features must leave OMNIGENT_FEATURES unset (upstream default)"
[ "$(features_of --set server.sessionOrchestration=true --set-string 'server.features=usage_page')" = "usage_page" ] || fail "sessionOrchestration=true must not append the disable"
if $HELM template t "$CHART_DIR" --set-string 'server.extraEnv[0].name=OMNIGENT_FEATURES' --set-string 'server.extraEnv[0].value=session_orchestration' >/dev/null 2>&1; then
  fail "server.extraEnv must not be able to set OMNIGENT_FEATURES"
fi
[ "$(env_of DATABASE_URL .value)" = "sqlite:////data/omnigent.db" ] || fail "DATABASE_URL must be SQLite on the PVC"
# server.database.existingSecret: DATABASE_URL from the Secret (exactly one entry, no
# leftover SQLite value) + a server egress rule to the in-namespace DB port; default = no such rule.
DB="$($HELM template t "$CHART_DIR" --set server.database.existingSecret=ext-db)"
DBENV="$(printf '%s' "$DB" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="DATABASE_URL")')"
[ "$(printf '%s' "$DBENV" | yq -N '.valueFrom.secretKeyRef.name')" = "ext-db" ] || fail "server.database.existingSecret must feed DATABASE_URL"
[ "$(printf '%s' "$DBENV" | yq -N '.valueFrom.secretKeyRef.key')" = "DATABASE_URL" ] || fail "server.database.existingSecretKey must default to DATABASE_URL"
[ "$(printf '%s' "$DBENV" | yq -N '.name' | wc -l)" = "1" ] || fail "exactly one DATABASE_URL env entry with an external database"
printf '%s' "$DBENV" | grep -q sqlite && fail "no SQLite DATABASE_URL may remain with an external database"
[ "$($HELM template t "$CHART_DIR" --set server.database.existingSecret=ext-db --set server.database.existingSecretKey=url | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="DATABASE_URL") | .valueFrom.secretKeyRef.key')" = "url" ] || fail "server.database.existingSecretKey not honoured"
printf '%s' "$DB" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="t-omnigent-allow") | .spec.egress[] | select(.to[0].podSelector != null) | .ports[0].port' | grep -qx 5432 || fail "external database needs server egress to the DB port"
[ "$($HELM template t "$CHART_DIR" --set server.database.existingSecret=ext-db --set server.database.egress.podSelector.app=db --set server.database.egress.port=6432 | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="t-omnigent-allow") | .spec.egress[] | select(.ports[0].port==6432) | .to[0].podSelector.matchLabels.app')" = "db" ] || fail "server.database.egress podSelector/port not honoured"
$HELM template t "$CHART_DIR" | yq -N 'select(.kind=="NetworkPolicy") | .spec.egress[]?.ports[]?.port' | grep -qx 5432 && fail "no DB egress rule without an external database"
SEC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Secret" and .metadata.name=="svc-aaaa1111-omnigent-secret")')"
[ "$(printf '%s' "$SEC" | yq '.stringData.admin_password | length')" -ge 20 ] || fail "self-generated admin_password too short"
printf '%s' "$SEC" | yq '.stringData.cookie_secret' | grep -qE '^[0-9a-f]{64}$' || fail "cookie_secret must be 64 hex chars (omnigent refuses anything else)"
PIN="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=pinned-by-platform | yq -N 'select(.kind=="Secret" and .metadata.name=="t-omnigent-secret") | .stringData.admin_password')"
[ "$PIN" = "pinned-by-platform" ] || fail "platform-pinned admin_password not honoured"
$HELM template t "$CHART_DIR" --set auth.existingSecret=ext | yq -N 'select(.kind=="Secret" and .metadata.name=="t-omnigent-secret") | .metadata.name' | grep -q . && fail "chart Secret rendered despite auth.existingSecret"
for bad in 'a:b' 'a b' ''; do
  $HELM template t "$CHART_DIR" --set-string "admin.username=$bad" >/dev/null 2>&1 && fail "admin.username '$bad' rendered — must be rejected"
done
$HELM template t "$CHART_DIR" --set server.baseUrl=https://x.example.io | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="OMNIGENT_ACCOUNTS_BASE_URL") | .value' | grep -qx 'https://x.example.io' || fail "server.baseUrl not wired to OMNIGENT_ACCOUNTS_BASE_URL"

# runners: kubernetes provider pointed at THIS namespace / release-named SA + Secret
CFG="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-omnigent-config") | .data["config.yaml"]')"
[ "$(printf '%s' "$CFG" | yq '.sandbox.provider')" = "kubernetes" ] || fail "sandbox provider must be kubernetes"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.namespace')" = "SENTINEL" ] || fail "runner namespace must be the release namespace"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.service_account')" = "svc-aaaa1111-omnigent-runner" ] || fail "runner SA must be release-named"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.secret_name')" = "svc-aaaa1111-omnigent-runner-env" ] || fail "runner env Secret must be release-named"
[ "$(printf '%s' "$CFG" | yq '.sandbox.server_url')" = "http://svc-aaaa1111-omnigent.SENTINEL.svc.cluster.local:8000" ] || fail "server_url must be the release Service"
printf '%s' "$OUT" | yq -N 'select(.kind=="Secret" and .metadata.name=="svc-aaaa1111-omnigent-runner-env") | .metadata.name' | grep -q . || fail "runner env Secret must exist before the first launch"
$HELM template t "$CHART_DIR" --set runner.image=ghcr.io/x/y:latest >/dev/null 2>&1 && fail "floating non-jcr runner.image must be rejected"
# AI-FIX-OMN-3-2 (AI-OMN-007-4): runner Jobs are built by the omnigent server at run time, so the
# operator's TENANT_AVOID_NODES post-renderer never sees them; upstream sandbox.kubernetes takes
# node_selector (equality) + tolerations only — no affinity key. Runners therefore pin to the nodes
# labelled paas.woowtech.io/tenant-schedulable=true (every node except ubuntuserver-59mqj).
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.node_selector["paas.woowtech.io/tenant-schedulable"]')" = "true" ] || fail "runners must default to node_selector paas.woowtech.io/tenant-schedulable=true (AI-FIX-OMN-3-2)"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.node_selector["paas.woowtech.io/tenant-schedulable"] | tag')" = "!!str" ] || fail "node_selector values must render as strings (upstream rejects non-string labels)"
[ "$($HELM template t "$CHART_DIR" --set-json 'runner.nodeSelector=null' | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-omnigent-config") | .data["config.yaml"]' | yq '.sandbox.kubernetes | has("node_selector")')" = "false" ] || fail "runner.nodeSelector=null must drop node_selector (escape hatch)"
ROLE="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Role")')"
printf '%s' "$ROLE" | yq '.rules[].resources[]' | grep -qx 'pods/exec' && fail "Role must not grant pods/exec"
printf '%s' "$ROLE" | yq '.rules[] | select(.resources[]=="secrets") | .verbs[]' | grep -qxE 'get|list|watch' && fail "Role must not read Secrets"
# #1536: the server SA must NOT be able to create a Pod (it creates Jobs; the Job
# controller makes the Pod). pods:create was the privileged-Pod node-escape vector.
PODVERBS="$(printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="pods" and (.resources | length)==1) | .verbs[]' | sort | paste -sd, -)"
[ "$PODVERBS" = "delete,get,list" ] || fail "pods verbs must be exactly delete,get,list (NO create) — got '$PODVERBS'"
printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="pods") | .verbs[]' | grep -qx create && fail "#1536: pods:create must be removed (privileged-Pod node escape)"
[ "$(printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="pods/log") | .verbs | join(",")')" = "get" ] || fail "pods/log must stay get (failure tails)"
printf '%s' "$OUT" | yq -N 'select(.kind=="ClusterRole" or .kind=="ClusterRoleBinding" or .kind=="Namespace") | .kind' | grep -q . && fail "no cluster-scoped objects allowed"
# AI-FIX-OMN-1（AI-OMN-006-1）：Role 的 secrets create/delete、pods delete、jobs create 無法用 resourceNames 限縮
# （名稱由 launcher 現產生），由 paas-operator chart 的叢集級 ValidatingAdmissionPolicy（omnigentSandboxGuard）
# 把 server SA 縮到 runner 物件。那條 policy 釘死這支 chart 的命名：server SA `<fullname>-server`、runner SA
# `<fullname>-runner`、envFrom Secret `<fullname>-runner-env`，並假設 Role 永遠不讀 Secret、不建 Pod。命名或
# Role 動到這幾點，要同步改 charts/paas-operator/templates/omnigent-sandbox-guard.yaml 與它的測試。
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="ServiceAccount" and .metadata.name=="svc-aaaa1111-omnigent-server") | .metadata.name')" = "svc-aaaa1111-omnigent-server" ] || fail "server SA must be <fullname>-server (omnigentSandboxGuard matches it)"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="RoleBinding") | .subjects[0].name')" = "svc-aaaa1111-omnigent-server" ] || fail "sandbox-manager RoleBinding must bind <fullname>-server"
[ "$(printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="secrets") | .verbs | sort | join(",")')" = "create,delete" ] || fail "secrets verbs must stay exactly create,delete (omnigentSandboxGuard assumes it)"
printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="secrets") | has("resourceNames")' | grep -qx true && fail "secrets create can never carry resourceNames — the guard policy is the control"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Role") | .metadata.name')" = "svc-aaaa1111-omnigent-sandbox-manager" ] || fail "Role name changed"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="ServiceAccount" and .metadata.name=="svc-aaaa1111-omnigent-runner") | .automountServiceAccountToken')" = "false" ] || fail "runner SA must not automount a token"
# #1349 runner-gc: runner Jobs (bare upstream Jobs, no owner) are adopted by the
# runner SA so `helm uninstall` GC's them. Same pinned server image, scoped RBAC.
GC="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="runner-gc")')"
[ "$(printf '%s' "$GC" | yq '.image')" = "$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].image')" ] || fail "runner-gc must reuse the pinned server image"
[ "$(printf '%s' "$GC" | yq '.env[] | select(.name=="RUNNER_SERVICE_ACCOUNT") | .value')" = "svc-aaaa1111-omnigent-runner" ] || fail "runner-gc must target this release's runner SA"
[ "$(printf '%s' "$GC" | yq '.env[] | select(.name=="NAMESPACE") | .valueFrom.fieldRef.fieldPath')" = "metadata.namespace" ] || fail "runner-gc namespace must come from the downward API"
printf '%s' "$GC" | yq '.resources.limits.cpu' | grep -q . || fail "runner-gc lacks limits (ResourceQuota)"
printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap") | .data["runner-gc.py"]' | grep -q 'ownerReferences' || fail "runner-gc script missing from the ConfigMap"
[ "$(printf '%s' "$ROLE" | yq '.rules[] | select(.resources[]=="serviceaccounts") | .resourceNames | join(",")')" = "svc-aaaa1111-omnigent-runner" ] || fail "serviceaccounts get must be pinned to the runner SA by resourceNames"
printf '%s' "$ROLE" | yq '.rules[] | select(.resources[]=="jobs") | .verbs[]' | grep -qx patch || fail "runner-gc needs jobs patch"
# #1536: optional hard age cap for runner Jobs — default 0 (off), plumbed to the sidecar.
[ "$(printf '%s' "$GC" | yq '.env[] | select(.name=="MAX_JOB_AGE_SECONDS") | .value')" = "0" ] || fail "runner-gc MAX_JOB_AGE_SECONDS must default to 0 (upstream 7-day behaviour)"
[ "$($HELM template t "$CHART_DIR" --set runner.gc.maxJobAgeSeconds=172800 | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="runner-gc") | .env[] | select(.name=="MAX_JOB_AGE_SECONDS") | .value')" = "172800" ] || fail "runner.gc.maxJobAgeSeconds must reach the sidecar env"
printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap") | .data["runner-gc.py"]' | grep -q 'MAX_JOB_AGE_SECONDS' || fail "runner-gc script must honour MAX_JOB_AGE_SECONDS"
# CPU budget: server + gc limits must stay within the 1 CPU the T1 quota gives the server
SRV_CPU="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources.limits.cpu')"; GC_CPU="$(printf '%s' "$GC" | yq '.resources.limits.cpu')"
m() { case "$1" in *m) echo "${1%m}";; *) echo "$(( $1 * 1000 ))";; esac; }
[ $(( $(m "$SRV_CPU") + $(m "$GC_CPU") )) -le 1000 ] || fail "server+runner-gc cpu limits exceed 1 CPU (breaks the two-runner T1 quota)"
NOGC="$($HELM template t "$CHART_DIR" --set runner.gc.enabled=false)"
printf '%s' "$NOGC" | grep -qE 'runner-gc|serviceaccounts' && fail "runner.gc.enabled=false must drop the sidecar, script and its RBAC"
OFF="$($HELM template t "$CHART_DIR" --set runner.enabled=false)"
[ "$(printf '%s' "$OFF" | yq 'select(.kind=="Deployment") | .spec.template.spec.containers | length')" = "1" ] || fail "runner.enabled=false must drop the runner-gc sidecar"
printf '%s' "$OFF" | yq -N 'select(.kind=="Role" or (.kind=="ConfigMap" and .metadata.name=="t-omnigent-config")) | .kind' | grep -q . && fail "runner.enabled=false must drop the Role and sandbox config"
[ "$(printf '%s' "$OFF" | yq 'select(.kind=="Deployment") | .spec.template.spec.automountServiceAccountToken')" = "false" ] || fail "no runners → no SA token on the server"

# #1379 tenant LLM keys: Secret only, authoritative, and they switch on host_config
cfg_of() { yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-omnigent-config") | .data["config.yaml"]'; }
renv_of() { yq -N 'select(.kind=="Secret" and .metadata.name=="t-omnigent-runner-env") | .data | map_values(@base64d)'; }
env_of_init() { printf '%s' "$DEP" | yq ".spec.template.spec.initContainers[] | select(.name==\"web-ui\") | .env[] | select(.name==\"$1\") | .value"; }
init_flag() { yq -N 'select(.kind=="Deployment") | .spec.template.spec.initContainers[] | select(.name=="web-ui") | .env[] | select(.name=="PAAS_LLM_CONFIGURED") | .value'; }
[ "$(printf '%s' "$CFG" | yq '.sandbox.host_config')" = "null" ] || fail "no LLM key → no host_config providers"
[ "$(printf '%s' "$OUT" | init_flag)" = "0" ] || fail "no LLM key → web UI must show the fill-in-a-key notice"
KEYED="$($HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=sk-or-SENTINEL)"
printf '%s' "$KEYED" | yq -N 'select(.kind!="Secret")' | grep -q 'sk-or-SENTINEL' && fail "LLM key leaked outside the runner env Secret"
printf '%s' "$KEYED" | yq -N 'select(.kind=="Secret" and .metadata.name=="t-omnigent-runner-env") | has("stringData")' | grep -qx true && fail "runner env Secret must use data (stringData keys are never removed on upgrade)"
# #1449: runners get the per-release PROXY TOKEN, the real key only the proxy Secret
PX="$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Secret" and .metadata.name=="t-omnigent-llm-proxy") | .data | map_values(@base64d)')"
[ "$(printf '%s' "$PX" | yq '.OPENROUTER_API_KEY')" = "sk-or-SENTINEL" ] || fail "auth.openrouterApiKey not in the LLM proxy Secret"
TOK="$(printf '%s' "$PX" | yq '.proxy_token')"
printf '%s' "$TOK" | grep -qE '^[A-Za-z0-9]{40,}$' || fail "proxy token missing or weak"
[ "$(printf '%s' "$KEYED" | renv_of | yq '.OPENROUTER_API_KEY')" = "$TOK" ] || fail "runner env must carry the proxy token (same render), not the key"
[ "$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Secret" and .metadata.name!="t-omnigent-llm-proxy") | .data | map_values(@base64d)' | grep -c 'sk-or-SENTINEL' || true)" = "0" ] || fail "real key in a Secret other than the proxy's"
printf '%s' "$KEYED" | yq -N 'select(.kind=="Deployment" and .metadata.name!="t-omnigent-llm-proxy") | .. | select(tag == "!!map" and has("secretKeyRef")) | .secretKeyRef.name' | grep -qx 't-omnigent-llm-proxy' && fail "only the proxy pod may reference the proxy Secret"
[ "$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Service" and .metadata.name=="t-omnigent-llm-proxy") | .spec.clusterIP')" = "None" ] || fail "proxy Service must be headless (the operator never tunnels to it)"
printf '%s' "$KEYED" | cfg_of | yq '.sandbox.host_config.providers.openrouter.openai.base_url' | grep -qx 'http://t-omnigent-llm-proxy.default.svc.cluster.local:8090/openrouter/api/v1' || fail "openrouter base_url must go through the proxy"
CONF="$(printf '%s' "$KEYED" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-omnigent-llm-proxy") | .data["nginx.conf"]')"
printf '%s' "$CONF" | grep -q 'proxy_ssl_verify on' || fail "proxy must verify the upstream certificate"
printf '%s' "$CONF" | grep -q 'woow_denied' || fail "proxy must check the token"
printf '%s' "$CONF" | grep -q 'log_format woow' || fail "proxy log format must not carry headers"
[ "$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Deployment" and .metadata.name=="t-omnigent-llm-proxy") | .spec.template.metadata.labels["app.kubernetes.io/name"]')" = "omnigent-llm-proxy" ] || fail "proxy pod must not carry the server's name label"
PK1="$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Deployment" and .metadata.name=="t-omnigent-llm-proxy") | .spec.template.metadata.annotations["checksum/config"]')"
PK2="$($HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=sk-or-OTHER | yq -N 'select(.kind=="Deployment" and .metadata.name=="t-omnigent-llm-proxy") | .spec.template.metadata.annotations["checksum/config"]')"
[ "$PK1" != "$PK2" ] || fail "a key change must restart the proxy"
$HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=x --set-string llmProxy.upstreams.openrouter='evil.io; return 200' >/dev/null 2>&1 && fail "malformed llmProxy upstream must be rejected"
NOPX="$($HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=sk-or-SENTINEL --set llmProxy.enabled=false)"
[ "$(printf '%s' "$NOPX" | renv_of | yq '.OPENROUTER_API_KEY')" = "sk-or-SENTINEL" ] || fail "llmProxy.enabled=false must put the key in the runner env (0.1.2 behaviour)"
printf '%s' "$NOPX" | cfg_of | yq '.sandbox.host_config.providers.openrouter.openai.base_url' | grep -qx 'https://openrouter.ai/api/v1' || fail "llmProxy.enabled=false must call OpenRouter directly"
printf '%s' "$NOPX" | grep -q 'llm-proxy' && fail "llmProxy.enabled=false must not render the proxy"
printf '%s' "$OUT" | yq -N 'select(.metadata.name=="svc-aaaa1111-omnigent-llm-proxy") | .kind' | grep -q . && fail "no key → no proxy objects"
KC="$(printf '%s' "$KEYED" | cfg_of)"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.providers.openrouter.openai.api_key_ref')" = "env:OPENROUTER_API_KEY" ] || fail "openrouter provider must read its key via api_key_ref env"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.providers.openrouter.openai.wire_api')" = "chat" ] || fail "OpenRouter speaks Chat Completions (wire_api: chat)"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses.pi.provider')" = "openrouter" ] || fail "pi must bind to openrouter"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses.pi.model_allowlist | length')" -ge 1 ] || fail "pi needs a model list (static catalog)"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses["opencode-native"].provider')" = "openrouter" ] || fail "OpenCode must bind to the configured gateway"
[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses["opencode-native"].default_model')" = "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses.pi.model_allowlist[0]')" ] || fail "OpenCode needs a valid default model"

[ "$(printf '%s' "$KC" | yq '.sandbox.host_config.inference.harnesses["claude-native"].model_allowlist | map(select(test("^anthropic/") | not)) | length')" = "0" ] || fail "Claude Code via OpenRouter may only list anthropic/* models"
[ "$(printf '%s' "$KEYED" | init_flag)" = "1" ] || fail "LLM key set → no notice"
[ "$(printf '%s' "$KEYED" | yq 'select(.kind=="Deployment") | .spec.template.metadata.annotations["checksum/config"]')" != "$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment") | .spec.template.metadata.annotations["checksum/config"]')" ] || fail "adding a key must restart the server (new host_config)"
AN="$($HELM template t "$CHART_DIR" --set-string auth.anthropicApiKey=sk-ant-x)"
[ "$(printf '%s' "$AN" | cfg_of | yq '.sandbox.host_config.inference.harnesses["claude-sdk"].provider')" = "anthropic" ] || fail "claude-sdk must bind to the Anthropic key"
[ "$(printf '%s' "$AN" | cfg_of | yq '.sandbox.host_config.inference.harnesses.pi.provider')" = "anthropic" ] || fail "pi falls back to Anthropic without OpenRouter"
[ "$(printf '%s' "$AN" | cfg_of | yq '.sandbox.host_config.inference.harnesses["opencode-native"]')" = "null" ] || fail "Anthropic-only must not configure OpenCode with an incompatible gateway"
$HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=x --set-string 'llm.openrouterModels=a b' >/dev/null 2>&1 && fail "malformed model ID must be rejected"
[ "$($HELM template t "$CHART_DIR" --set-string auth.openrouterApiKey=x --set-string runner.env.OPENROUTER_API_KEY=explicit | renv_of | yq '.OPENROUTER_API_KEY')" = "explicit" ] || fail "explicit runner.env must win over auth.*"
# #1358 web UI copy: init container patches a copy the server serves
[ "$(env_of OMNIGENT_WEB_UI_DIST .value)" = "/ui" ] || fail "server must serve the PaaS web UI copy"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].image')" = "$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].image')" ] || fail "web-ui init must reuse the pinned server image"
printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].resources.limits.cpu' | grep -q . || fail "web-ui init lacks limits (ResourceQuota)"
printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-omnigent-webui") | .data["paas-webui.py"]' | grep -q 'whoami' || fail "web-ui script missing"
NOUI="$($HELM template t "$CHART_DIR" --set webUi.paasCopy=false)"
printf '%s' "$NOUI" | grep -qE 'OMNIGENT_WEB_UI_DIST|initContainers|omnigent-webui' && fail "webUi.paasCopy=false must serve the stock UI"

# hardening / storage
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.securityContext.runAsNonRoot')" = "true" ] || fail "runAsNonRoot missing"
[ "$(printf '%s' "$DEP" | yq '.spec.strategy.type')" = "Recreate" ] || fail "strategy must be Recreate (RWO PVC + SQLite)"
[ "$(printf '%s' "$DEP" | yq '.spec.replicas')" = "1" ] || fail "SQLite is single-writer: replicas must be 1"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="PersistentVolumeClaim") | .spec.accessModes[0]')" = "ReadWriteOnce" ] || fail "PVC must be RWO"
printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources.limits.cpu' | grep -q . || fail "server lacks limits (ResourceQuota)"
printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.limits.cpu' | grep -q . || fail "runner Pods lack limits (ResourceQuota)"
# #1434 ephemeral-storage everywhere (server pod, runner Jobs, proxy); emptyDirs capped
for d in "$DEP" "$(printf '%s' "$KEYED" | yq -N 'select(.kind=="Deployment" and .metadata.name=="t-omnigent-llm-proxy")')"; do
  for c in $(printf '%s' "$d" | yq '.spec.template.spec | (.initContainers + .containers)[] | .name'); do
    printf '%s' "$d" | yq ".spec.template.spec | (.initContainers + .containers)[] | select(.name==\"$c\") | .resources.limits[\"ephemeral-storage\"]" | grep -qv null || fail "container $c lacks an ephemeral-storage limit (#1434)"
    printf '%s' "$d" | yq ".spec.template.spec | (.initContainers + .containers)[] | select(.name==\"$c\") | .resources.requests[\"ephemeral-storage\"]" | grep -qv null || fail "container $c lacks an ephemeral-storage request (#1434)"
  done
  [ "$(printf '%s' "$d" | yq '[.spec.template.spec.volumes[] | select(has("emptyDir")) | select(.emptyDir.sizeLimit == null)] | length')" = "0" ] || fail "an emptyDir without sizeLimit (#1434)"
done
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.limits["ephemeral-storage"]')" = "10Gi" ] || fail "runner Jobs need an ephemeral-storage limit >= HOME sizeLimit (#1434)"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.requests["ephemeral-storage"]')" != "null" ] || fail "runner Jobs need an ephemeral-storage request (#1434)"
# #1460: one session may use the plan minus the server (3 vCPU / 6 GiB)
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.limits.cpu')" = "3" ] || fail "runner cpu limit must be 3 (plan 4 - server 1, #1460)"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.limits.memory')" = "6Gi" ] || fail "runner memory limit must be 6Gi (plan 8 - server 1 - headroom, #1460)"
# #1451: the web UI says the cloud work machine's files are temporary
[ "$(env_of_init PAAS_EPHEMERAL_WORKSPACE)" = "1" ] || fail "runners on → ephemeral workspace notice"
[ "$($HELM template t "$CHART_DIR" --set runner.enabled=false | yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[] | select(.name=="web-ui") | .env[] | select(.name=="PAAS_EPHEMERAL_WORKSPACE") | .value')" = "0" ] || fail "runners off → no ephemeral notice"
# #1436 NetworkPolicy: no allow-all, private ranges excluded, runners have their own policy
[ -z "$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy") | [.spec.egress[] | select(has("to") | not)] | length' | grep -vx 0 || true)" ] || fail "an egress rule without 'to' (allow-all) is rendered by default"
SA="$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-omnigent-allow") | .spec.egress')"
printf '%s' "$SA" | yq '.[] | select(.to[0].ipBlock.cidr=="0.0.0.0/0") | .to[0].ipBlock.except[]' | grep -qx 10.0.0.0/8 || fail "server internet egress must exclude 10/8"
printf '%s' "$SA" | yq '.[] | select(.to[0].ipBlock.cidr=="0.0.0.0/0") | .to[0].ipBlock.except[]' | grep -qx 169.254.0.0/16 || fail "server internet egress must exclude metadata"
# 0.1.5 (#1441): no ":6443 on every RFC 1918 range" fallback any more — empty
# apiserverCidrs = the kubernetes Service ClusterIP alone; the platform injects the
# control-plane node /32s (woow_paas_platform.apiserver_cidrs).
[ "$(yq '[.[] | select(.ports[]?.port==6443) | .to[].ipBlock.cidr] | unique | join(",")' <<<"$SA")" = "10.43.0.1/32" ] || fail "default apiserver egress = 10.43.0.1/32 only (no RFC 1918 :6443 fallback)"
grep -qx 224.0.0.0/4 <<<"$(yq '.[] | select(.to[0].ipBlock.cidr=="0.0.0.0/0") | .to[0].ipBlock.except[]' <<<"$SA")" || fail "server internet egress must exclude multicast (#1441)"
grep -qxF '{"to":[{"podSelector":{}}]}' <<<"$(yq -o=json -I=0 '.[]' <<<"$SA")" || fail "server must reach every pod of the namespace (workspace = LAN, #1441)"
grep -qxF '{"from":[{"podSelector":{}}]}' <<<"$(printf '%s' "$OUT" | yq -N -o=json -I=0 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-omnigent-allow") | .spec.ingress[]')" || fail "every pod of the namespace must reach the server (#1441)"
$HELM template t "$CHART_DIR" --set 'networkPolicy.apiserverCidrs={192.168.10.21/32}' | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="t-omnigent-allow") | [.spec.egress[] | select(.ports[]?.port==6443) | .to[].ipBlock.cidr] | join(",")' | grep -x '192.168.10.21/32' >/dev/null || fail "injected apiserverCidrs must replace the fallback"
RP="$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-omnigent-runner-egress") | .spec')"
[ "$(printf '%s' "$RP" | yq '.podSelector.matchLabels["omnigent.ai/role"]')" = "sandbox-host" ] || fail "runner policy must select the upstream runner pods"
[ "$(printf '%s' "$RP" | yq '.policyTypes | join(",")')" = "Egress" ] || fail "runner policy is egress-only (ingress = operator baseline)"
printf '%s' "$RP" | yq '.egress[] | select(.to[0].podSelector.matchLabels["app.kubernetes.io/component"]=="server") | .ports[0].port' | grep -qx 8000 || fail "runners must reach this release's server on :8000"
printf '%s' "$RP" | yq '.egress[] | select(.to[0].ipBlock.cidr=="0.0.0.0/0") | .to[0].ipBlock.except[]' | grep -x 192.168.0.0/16 >/dev/null || fail "runner internet egress must exclude node IPs"
[ "$(yq '[.egress[] | select(.to[0].podSelector != null and (.to[0].podSelector | length) == 0)] | length' <<<"$RP")" = "1" ] || fail "runners reach the whole namespace by default (workspace = LAN, #1441)"
RP0="$($HELM template t "$CHART_DIR" --set networkPolicy.runner.sameNamespaceEgress=false | yq -N -o=json -I=0 'select(.kind=="NetworkPolicy" and .metadata.name=="t-omnigent-runner-egress") | .spec.egress[]')"
[ -n "$RP0" ] && ! grep -qxF '{"to":[{"podSelector":{}}]}' <<<"$RP0" || fail "runner.sameNamespaceEgress=false drops the namespace rule"
[ -z "$($HELM template t "$CHART_DIR" --set networkPolicy.allowAllEgress=true | yq -N -o=json -I=0 'select(.kind=="NetworkPolicy") | .spec.egress[] | select(has("to") | not)')" ] || fail "allowAllEgress=true must not render a bare {} any more (#1441)"
NS="$(printf '%s' "$OUT" | { grep -E '^  namespace:' || true; } | awk '{print $2}' | sort -u | tr '\n' ' ')"; [ -z "$NS" ] || [ "$NS" = "SENTINEL " ] || fail "hard-coded namespace: $NS"
# two releases in one namespace share no object name
A="$($HELM template svc-aaaa1111 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
B="$($HELM template svc-bbbb2222 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
[ -z "$(comm -12 <(printf '%s\n' "$A") <(printf '%s\n' "$B"))" ] || fail "two releases collide on object names"
echo "PASS (render-contract): server is the only port (no proxy), boot-time admin from Secret (pin/existing/lookup), hex cookie secret, sharing off, SQLite (or an external DATABASE_URL Secret with DB egress), kubernetes runners in-namespace with exec-less Role, runner-gc owner adoption (#1349), tenant LLM keys in the runner Secret + host_config (#1379), PaaS web UI copy (#1358), no cluster-scoped objects, non-root, RWO+Recreate, limits, collision-free names, LLM key proxy (#1449), ephemeral-storage (#1434), egress without allow-all incl. runners (#1436), runner sizing (#1460), temporary-workspace notice (#1451), runner node pin off 59mqj (AI-FIX-OMN-3-2)."
