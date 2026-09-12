#!/usr/bin/env bash
# Refuse an upgrade that would DELETE a live object holding irreplaceable data.
#
#   CONTEXT=woow-k3s RELEASE=omnigent NAMESPACE=omnigent \
#     VALUES=values/woow-k3s/omnigent.yaml scripts/preflight-retain.sh [--fix]
#
# WHY THIS EXISTS
# ---------------
# `helm upgrade` deletes every object that is in the STORED release manifest but
# not in the new render, unless the live object carries
# helm.sh/resource-policy: keep.
#
# The omnigent release is in exactly that state. Revision 10 was installed from
# a chart with secrets.create=true, so its stored manifest contains
# Secret/omnigent-admin and Secret/omnigent-postgres. The current chart defaults
# to secrets.create=false and renders neither, so the FIRST upgrade removes both
# — the admin credentials and the Postgres password/DATABASE_URL that the
# server, the runners, the host-gc CronJob and `helm test` all read. That is
# irreversible without a backup. Reproduced end to end in a test namespace:
# without the annotation both Secrets were `NotFound` after a `helm upgrade`
# that reported STATUS: deployed.
#
# A paragraph in the README is not a guard, so this script is wired into
# scripts/apply.sh upgrade (and into scripts/check-drift.sh as a read-only
# check). There is no skip flag.
#
# WHAT IT DOES
# ------------
#   1. stored   = objects in `helm get manifest <release>`
#   2. rendered = objects in `helm template` with the same values
#   3. orphans  = stored - rendered
#   For each orphan:
#     * gone from the cluster already  -> fine, the upgrade just forgets it
#       (the three runner Deployments this chart no longer renders were deleted
#        out of band and are in this bucket)
#     * live and annotated keep        -> fine, Helm will leave it alone
#     * live, data-bearing, no keep    -> BLOCK (or annotate it with --fix)
#     * live, not data-bearing, no keep-> loud warning, listed by name
#
# --fix adds `helm.sh/resource-policy: keep` to the blocking objects. That is
# an additive metadata annotation: it changes no pod template and restarts
# nothing. Read-only without it.
set -euo pipefail

CONTEXT="${CONTEXT:-woow-k3s}"
RELEASE="${RELEASE:-omnigent}"
NAMESPACE="${NAMESPACE:-omnigent}"
cd "$(dirname "$0")/.."
VALUES="${VALUES:-values/woow-k3s/omnigent.yaml}"
CHART="${CHART:-charts/omnigent}"

FIX=0
[ "${1:-}" = "--fix" ] && { FIX=1; shift; }

# Kinds whose deletion loses data that cannot be re-rendered from the chart.
PROTECTED_KINDS="Secret PersistentVolumeClaim ConfigMap Namespace"

command -v helm    >/dev/null || { echo "helm not installed"; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not installed"; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== preflight: objects this upgrade would remove from the release =="

if ! helm --kube-context "$CONTEXT" get manifest "$RELEASE" -n "$NAMESPACE" \
        > "$tmp/stored.yaml" 2>/dev/null; then
    echo "   no release $RELEASE in $NAMESPACE — nothing stored, nothing to orphan"
    exit 0
fi

helm template "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" --skip-tests "$@" \
    > "$tmp/render.yaml"

# `Kind<TAB>namespace<TAB>name` for both sides. Hooks in the stored manifest are
# ordinary objects here, which is what we want: Helm treats them the same way.
ids() {
    python3 - "$1" "$NAMESPACE" <<'PY'
import sys, yaml
path, default_ns = sys.argv[1], sys.argv[2]
for d in yaml.safe_load_all(open(path)):
    if not d or "kind" not in d:
        continue
    md = d.get("metadata") or {}
    print("\t".join([d["kind"], md.get("namespace") or default_ns, md.get("name", "")]))
PY
}

ids "$tmp/stored.yaml" | sort -u > "$tmp/stored.ids"
ids "$tmp/render.yaml" | sort -u > "$tmp/render.ids"
comm -23 "$tmp/stored.ids" "$tmp/render.ids" > "$tmp/orphans.ids"

if [ ! -s "$tmp/orphans.ids" ]; then
    echo "   the new render covers every object in the stored manifest — nothing to remove"
    exit 0
fi

blocking=""
blocking_display=""
while IFS=$'\t' read -r kind ns name; do
    [ -n "$kind" ] || continue
    if ! kubectl --context "$CONTEXT" -n "$ns" get "${kind,,}/${name}" \
            -o json > "$tmp/obj.json" 2>/dev/null; then
        echo "   ok        ${kind}/${name} — already absent from the cluster"
        continue
    fi
    policy="$(python3 -c 'import json,sys; print(((json.load(open(sys.argv[1])).get("metadata") or {}).get("annotations") or {}).get("helm.sh/resource-policy",""))' "$tmp/obj.json")"
    if [ "$policy" = "keep" ]; then
        echo "   ok        ${kind}/${name} — live, annotated helm.sh/resource-policy: keep"
        continue
    fi
    case " $PROTECTED_KINDS " in
        *" $kind "*)
            echo "   BLOCK     ${kind}/${name} — live, data-bearing, NOT annotated keep"
            blocking="${blocking}${kind}\t${ns}\t${name}\n"
            blocking_display="${blocking_display}     ${kind}/${name} (namespace ${ns})\n"
            ;;
        *)
            echo "   WARNING   ${kind}/${name} — live and WILL BE DELETED by this upgrade"
            echo "             (not data-bearing, so this is allowed — make sure it is intended)"
            ;;
    esac
done < "$tmp/orphans.ids"

if [ -z "$blocking" ]; then
    echo "   preflight OK"
    exit 0
fi

if [ "$FIX" = "1" ]; then
    echo
    echo "== --fix: annotating the blocking objects helm.sh/resource-policy=keep =="
    printf '%b' "$blocking" | while IFS=$'\t' read -r kind ns name; do
        [ -n "$kind" ] || continue
        kubectl --context "$CONTEXT" -n "$ns" annotate "${kind,,}/${name}" \
            helm.sh/resource-policy=keep --overwrite
    done
    echo "   done — re-run without --fix to confirm, then upgrade"
    exit 0
fi

cat >&2 <<EOF

XX PREFLIGHT FAILED — this upgrade would DELETE live objects that hold data the
   chart cannot re-create. Helm would report STATUS: deployed while doing it.

   Blocking objects:
$(printf '%b' "$blocking_display" | sed '/^[[:space:]]*$/d')

   Fix it (additive metadata only — no pod template changes, nothing restarts):

     CONTEXT=$CONTEXT RELEASE=$RELEASE NAMESPACE=$NAMESPACE \\
       VALUES=$VALUES scripts/preflight-retain.sh --fix

   or, through the documented upgrade path:

     RETAIN_FIX=1 KUBECONTEXT=$CONTEXT scripts/apply.sh upgrade

   Both add helm.sh/resource-policy: keep to the objects above, after which the
   upgrade leaves them in place and simply drops them from the release manifest.
EOF
exit 1
