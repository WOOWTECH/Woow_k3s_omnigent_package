#!/usr/bin/env bash
# Uninstall the omnigent release from a k3s cluster.
#
#   scripts/uninstall.sh              # helm uninstall; keeps the namespace,
#                                     # every PVC and the chart-created Secrets
#                                     # (keepOnUninstall=true adds
#                                     #  helm.sh/resource-policy: keep to them)
#   scripts/uninstall.sh --purge      # also delete PVCs (pi-agent + Postgres +
#                                     # server state loss), the CF creds Secret
#                                     # and the namespace
set -euo pipefail

NAMESPACE="${NAMESPACE:-omnigent}"
RELEASE="${RELEASE:-omnigent}"
[ -n "${KUBECONTEXT:-}" ] || { echo "KUBECONTEXT env required"; exit 1; }

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

helm --kube-context "${KUBECONTEXT}" uninstall "${RELEASE}" -n "${NAMESPACE}" || true

if [ "${1:-}" = "--purge" ]; then
    say "deleting PVCs (pi state + postgres data + server data)"
    kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete pvc \
        --selector "app.kubernetes.io/managed-by=Helm,app.kubernetes.io/name=omnigent" \
        --ignore-not-found

    say "deleting cloudflared credentials Secret"
    kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete secret omnigent-cloudflared-creds --ignore-not-found

    say "deleting namespace"
    kubectl --context "${KUBECONTEXT}" delete ns "${NAMESPACE}" --ignore-not-found
fi

say "done"
