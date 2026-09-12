#!/usr/bin/env bash
# Compare this chart with what is running. Exit 0 = in sync, 1 = drift.
#   1. repo vs release : helm template (this repo) <-> helm get manifest
#   2. repo vs cluster : rendered objects <-> live objects, field by field,
#                        after stripping status and server-side defaults
#
#   CONTEXT=woow-k3s RELEASE=omnigent NAMESPACE=omnigent \
#     VALUES=values/woow-k3s/omnigent.yaml scripts/check-drift.sh
#
# Read-only: every kubectl call is a `get`. Extra arguments are passed to
# `helm template`.
#
# Check 1 is expected to report differences until the next `helm upgrade`, because
# the stored release manifest is the pre-write-back one. Check 2 is the one that
# must be clean: it compares against the objects that are actually running,
# including everything applied with `kubectl patch` outside Helm.
set -euo pipefail

CONTEXT="${CONTEXT:-woow-k3s}"
RELEASE="${RELEASE:-omnigent}"
NAMESPACE="${NAMESPACE:-omnigent}"
cd "$(dirname "$0")/.."
VALUES="${VALUES:-values/woow-k3s/omnigent.yaml}"

command -v helm    >/dev/null || { echo "helm not installed"; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not installed"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm template "$RELEASE" charts/omnigent -n "$NAMESPACE" -f "$VALUES" --skip-tests "$@" > "$tmp/repo.yaml"

rc=0

echo "== 1. repo render vs stored release manifest =="
if helm --kube-context "$CONTEXT" get manifest "$RELEASE" -n "$NAMESPACE" > "$tmp/release.yaml" 2>/dev/null; then
  # -B: `helm get manifest` ends with a blank line that `helm template` does not.
  if diff -u -B "$tmp/release.yaml" "$tmp/repo.yaml" > "$tmp/repo.diff"; then
    echo "   repo == release $RELEASE"
  else
    echo "   differs from the stored manifest (expected before the first upgrade):"
    sed -n '1,80p' "$tmp/repo.diff"
    rc=1
  fi
else
  echo "   no release $RELEASE in $NAMESPACE — skipped"
fi

echo "== 2. repo render vs live objects =="
python3 scripts/normalize.py --render "$tmp/repo.yaml" --context "$CONTEXT" --namespace "$NAMESPACE" || rc=1

exit "$rc"
