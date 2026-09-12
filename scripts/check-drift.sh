#!/usr/bin/env bash
# Compare this chart with what is running. Exit 0 = in sync, 1 = drift.
#   1. repo vs release : helm template (this repo) <-> helm get manifest
#   2. repo vs cluster : rendered objects <-> live objects, field by field,
#                        in BOTH directions (scripts/normalize.py), after
#                        stripping status and known server-side defaults
#   3. upgrade safety  : would an upgrade delete live data the render omits?
#                        (scripts/preflight-retain.sh, read-only here)
#
# DO NOT derive the reference with `helm get values omnigent`. Revision 10 was
# installed from a values file that still carried the admin and Postgres
# passwords, so that command prints both in clear text into your terminal and
# your shell history. Use `helm get manifest` (check 1) or `kubectl get -o yaml`
# (check 2) — neither exposes a credential. Rotating those passwords is on the
# PR's follow-up list; until then treat `helm get values` on this release as a
# credential dump.
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
# The setup-admin Job is named per release revision (…-setup-admin-<revision>),
# so `helm template` always renders …-1 and the cluster never has it. Declare it
# instead of letting it read as a missing object.
EXPECT_NEW=()
while IFS= read -r j; do
  EXPECT_NEW+=(--expect-new "Job/$j")
done < <(python3 -c 'import sys,yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    print(d["metadata"]["name"]) if d and d.get("kind")=="Job" else None' "$tmp/repo.yaml")
python3 scripts/normalize.py --render "$tmp/repo.yaml" \
  --context "$CONTEXT" --namespace "$NAMESPACE" \
  "${EXPECT_NEW[@]+"${EXPECT_NEW[@]}"}" || rc=1

echo
# Read-only (no --fix): reports whether the first upgrade from the stored
# manifest would delete live, data-bearing objects this render no longer
# carries. Expected to fail on the omnigent release until the two Secrets are
# annotated helm.sh/resource-policy: keep — scripts/apply.sh upgrade enforces
# the same check and refuses to run without it.
CONTEXT="$CONTEXT" RELEASE="$RELEASE" NAMESPACE="$NAMESPACE" VALUES="$VALUES" \
    scripts/preflight-retain.sh || rc=1

exit "$rc"
