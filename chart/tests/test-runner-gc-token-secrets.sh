#!/usr/bin/env bash
# runner-gc reaps orphaned runner token Secrets (AI-FIX-OMN-1-1).
#
# Upstream's kubernetes launcher creates `<job>-token` (Opaque, labels
# managed-by=omnigent + role=sandbox-host, NO ownerReferences) before each runner
# Job and deletes it only from its own terminate()/start-failure paths. When the
# Job goes away any other way — ttlSecondsAfterFinished (24 h after a Job ends on
# its own), the runner-SA ownerReference cascade, runner-gc's own max-age delete,
# a terminate() whose Secret delete failed — the token Secret stays forever
# (paas-ws-7a3676a7 had 4, 12 days old). runner-gc already lists this release's
# runner Jobs; it now remembers their names and deletes `<name>-token` once a Job
# has been gone for a grace period, using the `secrets: delete` verb the server SA
# already holds — NO new RBAC (secrets list/get/patch would let a leaked server
# token read every Secret in the workspace namespace).
#
# Render contract here; behaviour in runner_gc_token_secrets.py, run against the
# runner-gc.py helm actually renders into the ConfigMap.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (runner-gc-token-secrets): yq (mikefarah) required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP (runner-gc-token-secrets): python3 required"; exit 0; }
fail() { echo "FAIL (runner-gc-token-secrets): $1"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

OUT="$($HELM template svc-aaaa1111-omnigent "$CHART_DIR")"
GC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="runner-gc")')"
genv() { printf '%s' "$GC" | yq ".env[] | select(.name==\"$1\") | .value"; }
[ "$(genv REAP_TOKEN_SECRETS)" = "1" ] || fail "runner-gc must reap orphaned token Secrets by default (REAP_TOKEN_SECRETS=1)"
[ "$(genv TOKEN_SECRET_GRACE_SECONDS)" = "120" ] || fail "TOKEN_SECRET_GRACE_SECONDS must default to 120"
[ "$(genv STATE_FILE)" = "/tmp/runner-gc-state.json" ] || fail "state must live on the pod's /tmp emptyDir (survives a sidecar restart)"
printf '%s' "$GC" | yq '.volumeMounts[] | select(.mountPath=="/tmp") | .name' | grep -qx tmp || fail "runner-gc must mount the tmp emptyDir at /tmp"
OFF="$($HELM template t "$CHART_DIR" --set runner.gc.reapTokenSecrets=false --set runner.gc.tokenSecretGraceSeconds=600)"
OGC="$(printf '%s' "$OFF" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="runner-gc")')"
[ "$(printf '%s' "$OGC" | yq '.env[] | select(.name=="REAP_TOKEN_SECRETS") | .value')" = "0" ] || fail "runner.gc.reapTokenSecrets=false must reach the sidecar"
[ "$(printf '%s' "$OGC" | yq '.env[] | select(.name=="TOKEN_SECRET_GRACE_SECONDS") | .value')" = "600" ] || fail "runner.gc.tokenSecretGraceSeconds must reach the sidecar"

# No new RBAC: the reaper uses the delete verb the launcher already needs.
ROLE="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Role")')"
SV="$(printf '%s' "$ROLE" | yq -N '.rules[] | select(.resources[]=="secrets") | .verbs[]' | sort | paste -sd, -)"
[ "$SV" = "create,delete" ] || fail "server SA secrets verbs must stay exactly create,delete (got '$SV') — list/get/patch would expose every Secret"

printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-omnigent-config") | .data["runner-gc.py"]' > "$TMP/runner-gc.py"
[ -s "$TMP/runner-gc.py" ] || fail "runner-gc.py missing from the ConfigMap"
python3 "$(dirname "${BASH_SOURCE[0]}")/runner_gc_token_secrets.py" "$TMP/runner-gc.py" || fail "runner-gc token-Secret behaviour (see above)"
echo "PASS (runner-gc-token-secrets)"
