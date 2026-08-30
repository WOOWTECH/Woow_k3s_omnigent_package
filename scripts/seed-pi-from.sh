#!/usr/bin/env bash
# One-shot: copy pi state (providers/models/skills/mcp) from a live
# `Woow_k3s_pi_agent_package` pod into an omnigent runner's fresh PVC so
# chat sessions can invoke an LLM without operator running `pi setup` inside
# every runner.
#
# Usage:
#   KUBECONTEXT=woow-k3s NAMESPACE=omnigent \
#     scripts/seed-pi-from.sh <source-ns> <source-pod> <runner-host>
#
# Example:
#   KUBECONTEXT=woow-k3s NAMESPACE=omnigent \
#     scripts/seed-pi-from.sh pi-agent-woow pi-agent-65669d447f-xmwbs pi1
#
# Q5 (chart values) defaults to fresh per-runner PVCs — this script is the
# escape hatch when you want a pi-web-configured starting point. The source
# pi-agent pod must have `tar` installed (the pi-web image does).
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <source-ns> <source-pod> <runner-host>" >&2; exit 1; }
SRC_NS="$1"
SRC_POD="$2"
DST_HOST="$3"

: "${KUBECONTEXT:?KUBECONTEXT env required}"
: "${NAMESPACE:=omnigent}"

kctx() { kubectl --context "${KUBECONTEXT}" "$@"; }

# Find the runner pod for the given host name
DST_POD=$(kctx -n "${NAMESPACE}" get pod \
    -l "app.kubernetes.io/component=runner,app.kubernetes.io/instance-host=${DST_HOST}" \
    -o jsonpath='{.items[0].metadata.name}')
[ -n "${DST_POD}" ] || { echo "no runner pod for host ${DST_HOST}" >&2; exit 1; }

echo "==> source: ${SRC_NS}/${SRC_POD} (container pi-web)"
echo "==> dest:   ${NAMESPACE}/${DST_POD} (runner PVC via /data/pi-agent)"
SRC_SIZE=$(kctx -n "${SRC_NS}" exec "${SRC_POD}" -c pi-web -- \
    du -sb /data/pi-agent 2>/dev/null | awk '{print $1}')
echo "==> streaming tar of ~$(numfmt --to=iec "${SRC_SIZE}" 2>/dev/null || echo "${SRC_SIZE} bytes"); expect several minutes on a 5-20GB pi-agent volume"

# tar from src → stdout → tar in dst /data/pi-agent
# Skip volatile subdirs (lost+found, sessions/, logs) to keep the copy small
# and not stomp on runner-local session ids that omnigent already wrote.
if command -v pv >/dev/null 2>&1; then
    kctx -n "${SRC_NS}" exec "${SRC_POD}" -c pi-web -- \
        tar -C /data/pi-agent -cf - \
            --exclude='./lost+found' \
            --exclude='./home/.omnigent/logs' \
            --exclude='./missions/log' \
            . \
    | pv -s "${SRC_SIZE:-0}" \
    | kctx -n "${NAMESPACE}" exec -i "${DST_POD}" -c runner -- \
        tar -C /data/pi-agent -xf -
else
    # No pv — silent transfer; progress not visible until done.
    kctx -n "${SRC_NS}" exec "${SRC_POD}" -c pi-web -- \
        tar -C /data/pi-agent -cf - \
            --exclude='./lost+found' \
            --exclude='./home/.omnigent/logs' \
            --exclude='./missions/log' \
            . \
    | kctx -n "${NAMESPACE}" exec -i "${DST_POD}" -c runner -- \
        tar -C /data/pi-agent -xf -
fi

echo "==> restart runner-${DST_HOST} to re-read providers"
kctx -n "${NAMESPACE}" rollout restart deploy/omnigent-runner-"${DST_HOST}"
kctx -n "${NAMESPACE}" rollout status deploy/omnigent-runner-"${DST_HOST}" --timeout=2m

echo "==> done. Open https://omnigent.woowtech.io/ and pick host ${DST_HOST}; pi should now have inherited providers."
