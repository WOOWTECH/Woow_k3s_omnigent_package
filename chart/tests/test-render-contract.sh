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
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l)" = "1" ] || fail "expected exactly one Service"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name')" = "svc-aaaa1111-omnigent" ] || fail "entrance Service must be the un-suffixed fullname"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.type')" = "ClusterIP" ] || fail "Service is not ClusterIP"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.ports[0].targetPort')" = "8000" ] || fail "Service targetPort != 8000"
printf '%s' "$OUT" | grep -qiE 'cloudflared|pgbouncer|postgres|nginx' && fail "cloudflared/postgres/pgbouncer/nginx must not be rendered"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.containers | length')" = "1" ] || fail "server pod must have exactly one container (no auth-proxy sidecar)"

# auth: accounts provider, boot-time admin from the Secret, sharing off
[ "$(env_of OMNIGENT_AUTH_PROVIDER .value)" = "accounts" ] || fail "OMNIGENT_AUTH_PROVIDER must be accounts"
[ "$(env_of OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD .valueFrom.secretKeyRef.key)" = "admin_password" ] || fail "INIT_ADMIN_PASSWORD must come from Secret admin_password"
[ "$(env_of OMNIGENT_ACCOUNTS_COOKIE_SECRET .valueFrom.secretKeyRef.key)" = "cookie_secret" ] || fail "cookie secret must come from the Secret"
[ "$(env_of OMNIGENT_PUBLIC_SHARING .value)" = "0" ] || fail "public sharing must default off"
[ "$(env_of DATABASE_URL .value)" = "sqlite:////data/omnigent.db" ] || fail "DATABASE_URL must be SQLite on the PVC"
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
CFG="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap") | .data["config.yaml"]')"
[ "$(printf '%s' "$CFG" | yq '.sandbox.provider')" = "kubernetes" ] || fail "sandbox provider must be kubernetes"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.namespace')" = "SENTINEL" ] || fail "runner namespace must be the release namespace"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.service_account')" = "svc-aaaa1111-omnigent-runner" ] || fail "runner SA must be release-named"
[ "$(printf '%s' "$CFG" | yq '.sandbox.kubernetes.secret_name')" = "svc-aaaa1111-omnigent-runner-env" ] || fail "runner env Secret must be release-named"
[ "$(printf '%s' "$CFG" | yq '.sandbox.server_url')" = "http://svc-aaaa1111-omnigent.SENTINEL.svc.cluster.local:8000" ] || fail "server_url must be the release Service"
printf '%s' "$OUT" | yq -N 'select(.kind=="Secret" and .metadata.name=="svc-aaaa1111-omnigent-runner-env") | .metadata.name' | grep -q . || fail "runner env Secret must exist before the first launch"
$HELM template t "$CHART_DIR" --set runner.image=ghcr.io/x/y:latest >/dev/null 2>&1 && fail "floating non-jcr runner.image must be rejected"
ROLE="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Role")')"
printf '%s' "$ROLE" | yq '.rules[].resources[]' | grep -qx 'pods/exec' && fail "Role must not grant pods/exec"
printf '%s' "$ROLE" | yq '.rules[] | select(.resources[]=="secrets") | .verbs[]' | grep -qxE 'get|list|watch' && fail "Role must not read Secrets"
printf '%s' "$OUT" | yq -N 'select(.kind=="ClusterRole" or .kind=="ClusterRoleBinding" or .kind=="Namespace") | .kind' | grep -q . && fail "no cluster-scoped objects allowed"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="ServiceAccount" and .metadata.name=="svc-aaaa1111-omnigent-runner") | .automountServiceAccountToken')" = "false" ] || fail "runner SA must not automount a token"
OFF="$($HELM template t "$CHART_DIR" --set runner.enabled=false)"
printf '%s' "$OFF" | yq -N 'select(.kind=="Role" or .kind=="ConfigMap") | .kind' | grep -q . && fail "runner.enabled=false must drop the Role and sandbox config"
[ "$(printf '%s' "$OFF" | yq 'select(.kind=="Deployment") | .spec.template.spec.automountServiceAccountToken')" = "false" ] || fail "no runners → no SA token on the server"

# hardening / storage
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.securityContext.runAsNonRoot')" = "true" ] || fail "runAsNonRoot missing"
[ "$(printf '%s' "$DEP" | yq '.spec.strategy.type')" = "Recreate" ] || fail "strategy must be Recreate (RWO PVC + SQLite)"
[ "$(printf '%s' "$DEP" | yq '.spec.replicas')" = "1" ] || fail "SQLite is single-writer: replicas must be 1"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="PersistentVolumeClaim") | .spec.accessModes[0]')" = "ReadWriteOnce" ] || fail "PVC must be RWO"
printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources.limits.cpu' | grep -q . || fail "server lacks limits (ResourceQuota)"
printf '%s' "$CFG" | yq '.sandbox.kubernetes.resources.limits.cpu' | grep -q . || fail "runner Pods lack limits (ResourceQuota)"
NS="$(printf '%s' "$OUT" | { grep -E '^  namespace:' || true; } | awk '{print $2}' | sort -u | tr '\n' ' ')"; [ -z "$NS" ] || [ "$NS" = "SENTINEL " ] || fail "hard-coded namespace: $NS"
# two releases in one namespace share no object name
A="$($HELM template svc-aaaa1111 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
B="$($HELM template svc-bbbb2222 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
[ -z "$(comm -12 <(printf '%s\n' "$A") <(printf '%s\n' "$B"))" ] || fail "two releases collide on object names"
echo "PASS (render-contract): server is the only port (no proxy), boot-time admin from Secret (pin/existing/lookup), hex cookie secret, sharing off, SQLite, kubernetes runners in-namespace with exec-less Role, no cluster-scoped objects, non-root, RWO+Recreate, limits, collision-free names."
