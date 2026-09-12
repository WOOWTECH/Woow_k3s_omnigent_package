#!/usr/bin/env bash
# Apply the omnigent chart to a k3s cluster.
#
#   scripts/apply.sh                # dry-run: `helm template …`
#   scripts/apply.sh install        # install into $NAMESPACE (default: omnigent)
#   scripts/apply.sh upgrade        # helm upgrade on existing release
#
# Env:
#   KUBECONTEXT   kubectl/helm context to target (required for install/upgrade)
#   NAMESPACE     k8s namespace (default: omnigent)
#   RELEASE       helm release name (default: omnigent)
#   CF_CREDS_JSON path to cloudflared credentials.json (default:
#                 /tmp/omnigent-tunnel-creds.json)
#   VALUES        instance values file (default: values/woow-k3s/omnigent.yaml)
#   TIMEOUT       helm --timeout (default: 15m)
#   RETAIN_FIX    upgrade only: let the retain preflight annotate the objects
#                 it would otherwise block on (see below)
#
# UPGRADE SAFETY: `upgrade` always runs scripts/preflight-retain.sh first and
# refuses to continue if this render would delete a live, data-bearing object
# that the stored release manifest still carries. On this release that is
# Secret/omnigent-admin and Secret/omnigent-postgres — revision 10 was installed
# with secrets.create=true, the chart now defaults to false, and a plain
# `helm upgrade` deletes both while reporting STATUS: deployed. There is no skip
# flag: either annotate them yourself, or re-run with RETAIN_FIX=1 and let the
# preflight do it. The annotation is additive metadata and restarts nothing.
#
# Credentials: the chart does NOT carry admin or Postgres passwords. Either the
# Secrets omnigent-admin and omnigent-postgres already exist in the namespace
# (see examples/secrets.example.yaml), or pass --set secrets.create=true plus
# admin.username / admin.password / postgres.password on a fresh install.
#
# The chart's cloudflared sidecar expects a Secret with two keys:
#   credentials.json — the tunnel creds you got from `cloudflared tunnel create`
#                      (or the CF API POST /accounts/{id}/cfd_tunnel)
#   config.yaml      — a minimal cloudflared config pointing at the tunnel
# This script mints both automatically from CF_CREDS_JSON.
set -euo pipefail

MODE="${1:-render}"
NAMESPACE="${NAMESPACE:-omnigent}"
RELEASE="${RELEASE:-omnigent}"
CF_CREDS_JSON="${CF_CREDS_JSON:-/tmp/omnigent-tunnel-creds.json}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_DIR}/charts/omnigent"
VALUES="${VALUES:-${REPO_DIR}/values/woow-k3s/omnigent.yaml}"
TIMEOUT="${TIMEOUT:-15m}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

command -v helm    >/dev/null || die "helm not installed"
command -v kubectl >/dev/null || die "kubectl not installed"

if [ "$MODE" = "render" ]; then
    say "helm template (dry-run)"
    helm template "${RELEASE}" "${CHART_DIR}" \
        -f "${VALUES}" \
        --namespace "${NAMESPACE}"
    exit 0
fi

[ -n "${KUBECONTEXT:-}" ] || die "KUBECONTEXT must be set for install/upgrade (e.g. woow-k3s)"

kubectl_ctx() { kubectl --context "${KUBECONTEXT}" "$@"; }
helm_ctx()    { helm    --kube-context "${KUBECONTEXT}" "$@"; }

say "target: context=${KUBECONTEXT} namespace=${NAMESPACE} release=${RELEASE}"

# Namespace
kubectl_ctx get ns "${NAMESPACE}" >/dev/null 2>&1 || {
    say "creating namespace ${NAMESPACE}"
    kubectl_ctx create ns "${NAMESPACE}"
}

# Cloudflared secret — chart's sidecar volume-mounts a projected Secret with
# credentials.json + config.yaml. Mint both here so the chart stays credentials-agnostic.
if [ ! -f "${CF_CREDS_JSON}" ]; then
    warn "CF_CREDS_JSON not found at ${CF_CREDS_JSON} — skipping cloudflared Secret creation."
    warn "The cloudflared Deployment will crashloop until you kubectl create secret it manually."
else
    TUNNEL_ID="$(jq -r .TunnelID "${CF_CREDS_JSON}")"
    [ -n "${TUNNEL_ID}" ] && [ "${TUNNEL_ID}" != "null" ] || die "TunnelID missing from ${CF_CREDS_JSON}"
    CFG_YAML="$(mktemp)"
    cat > "${CFG_YAML}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json
metrics: 0.0.0.0:2000
no-autoupdate: true
EOF
    say "recreating Secret omnigent-cloudflared-creds"
    kubectl_ctx -n "${NAMESPACE}" delete secret omnigent-cloudflared-creds --ignore-not-found
    kubectl_ctx -n "${NAMESPACE}" create secret generic omnigent-cloudflared-creds \
        --from-file=credentials.json="${CF_CREDS_JSON}" \
        --from-file=config.yaml="${CFG_YAML}"
    rm -f "${CFG_YAML}"
fi

case "$MODE" in
    install)
        say "helm install ${RELEASE}"
        helm_ctx install "${RELEASE}" "${CHART_DIR}" \
            --namespace "${NAMESPACE}" \
            -f "${VALUES}" \
            --wait --timeout "${TIMEOUT}" "${@:2}"
        ;;
    upgrade)
        # Unskippable: refuse to delete live data the new render omits.
        say "retain preflight (scripts/preflight-retain.sh)"
        PREFLIGHT_ARGS=()
        [ "${RETAIN_FIX:-0}" = "1" ] && PREFLIGHT_ARGS+=(--fix)
        CONTEXT="${KUBECONTEXT}" RELEASE="${RELEASE}" NAMESPACE="${NAMESPACE}" \
        VALUES="${VALUES}" CHART="${CHART_DIR}" \
            "${REPO_DIR}/scripts/preflight-retain.sh" "${PREFLIGHT_ARGS[@]+"${PREFLIGHT_ARGS[@]}"}" \
            || die "retain preflight refused the upgrade (see above) — nothing was changed"
        if [ "${RETAIN_FIX:-0}" = "1" ]; then
            CONTEXT="${KUBECONTEXT}" RELEASE="${RELEASE}" NAMESPACE="${NAMESPACE}" \
            VALUES="${VALUES}" CHART="${CHART_DIR}" \
                "${REPO_DIR}/scripts/preflight-retain.sh" \
                || die "retain preflight still refuses after --fix — stop and investigate"
        fi

        say "helm upgrade ${RELEASE}"
        helm_ctx upgrade "${RELEASE}" "${CHART_DIR}" \
            --namespace "${NAMESPACE}" \
            -f "${VALUES}" \
            --wait --timeout "${TIMEOUT}" "${@:2}"
        ;;
    *)
        die "unknown mode: $MODE (render|install|upgrade)"
        ;;
esac

say "helm status"
helm_ctx status "${RELEASE}" -n "${NAMESPACE}"

say "pods"
kubectl_ctx -n "${NAMESPACE}" get pods -o wide

say "public URL: https://omnigent.woowtech.io  (cloudflared may take ~30s to warm up)"
