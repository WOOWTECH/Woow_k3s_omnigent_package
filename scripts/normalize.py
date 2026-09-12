#!/usr/bin/env python3
"""Field-by-field comparison of a rendered chart against the live objects.

BOTH DIRECTIONS ARE ENFORCED.

  render -> live   every field the chart DECLARES must exist live with the same
                   value (anything else is drift, or an intended render-only
                   addition listed in EXPECTED_RENDER_ONLY).
  live -> render   every field that exists ONLY live must be a known
                   API-server/controller default from SERVER_DEFAULTS below.
                   Anything else is an operator-set field the chart has
                   forgotten, and it fails.

The second direction is the point of this rewrite. The earlier version walked
render -> live only and printed every live-only field with the hard-coded text
"live-only (server default)" without touching the exit code. That is how the
`kubectl patch` resources block on CronJob/omnigent-host-gc was mislabelled as
an API-server default and shipped as "no drift": the chart had no
hostGc.resources key at all, so no values file could reproduce the live
CronJob, and a fresh install or DR rebuild would silently drop the limits.

SERVER_DEFAULTS is deliberately narrow. Every entry is a fixed normalized path
(list indices collapsed to `[]`) plus the exact value(s) the API server is
allowed to have defaulted it to. A live `spec.strategy` of
{type: RollingUpdate, maxSurge 25%, maxUnavailable 25%} is a default; a live
`spec.strategy` of {type: Recreate} on an object whose template does not
declare one is drift and will fail. Adding an entry here is a deliberate act:
if a real field is missing from the chart, add it to the chart instead.

  python3 scripts/normalize.py --render /tmp/repo.yaml \
      --context woow-k3s --namespace omnigent

Exit 0 when every declared field matches and every live-only field is a known
default, 1 otherwise. Read-only: `kubectl get` and nothing else.

NOTE on deriving the reference: use `helm get manifest` or `kubectl get -o yaml`.
Do NOT use `helm get values` on the omnigent release — revision 10 was
installed from a values file that still carried the admin and Postgres
passwords, so `helm get values` prints them in clear text into your terminal
and your shell history.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("pyyaml required: pip install pyyaml")

# Metadata that Helm or the API server adds on apply; never part of a render.
IGNORED_META_ANNOTATIONS = (
    "meta.helm.sh/release-name",
    "meta.helm.sh/release-namespace",
    "deployment.kubernetes.io/revision",
    "pv.kubernetes.io/bind-completed",
    "pv.kubernetes.io/bound-by-controller",
    "volume.beta.kubernetes.io/storage-provisioner",
    "volume.kubernetes.io/storage-provisioner",
    "kubectl.kubernetes.io/last-applied-configuration",
)

# Render-only fields that are expected and intended (documented in the PR).
# path prefix -> reason
EXPECTED_RENDER_ONLY = {
    "metadata.annotations.helm.sh/resource-policy":
        "keepOnUninstall: uninstall must not delete data (metadata only)",
}

ANY = object()   # value is entirely server-assigned; presence alone is fine
EMPTY = object()  # allowed only when the live value is an empty dict/list

# Live-only fields the API server / a core controller is allowed to add.
# normalized path -> allowed value, list of allowed values, ANY or EMPTY.
#
# Keep this list short and value-constrained. An unconstrained entry is a hole
# exactly the size of the field.
SERVER_DEFAULTS: dict[str, object] = {
    # --- object metadata ---------------------------------------------------
    # PVC protection finalizer, added by the PV controller on bind.
    "metadata.finalizers": [["kubernetes.io/pvc-protection"]],

    # --- Service -----------------------------------------------------------
    "spec.clusterIP": ANY,
    "spec.clusterIPs": ANY,
    "spec.ipFamilies": ANY,
    "spec.ipFamilyPolicy": ["SingleStack"],
    "spec.internalTrafficPolicy": ["Cluster"],
    "spec.sessionAffinity": ["None"],
    "spec.ports[].protocol": ["TCP"],

    # --- Deployment / StatefulSet / CronJob object-level defaults ----------
    "spec.progressDeadlineSeconds": [600],
    "spec.revisionHistoryLimit": [10],
    "spec.strategy": [{"type": "RollingUpdate",
                       "rollingUpdate": {"maxSurge": "25%",
                                         "maxUnavailable": "25%"}}],
    "spec.updateStrategy": [{"type": "RollingUpdate",
                             "rollingUpdate": {"partition": 0}}],
    "spec.podManagementPolicy": ["OrderedReady"],
    "spec.persistentVolumeClaimRetentionPolicy":
        [{"whenDeleted": "Retain", "whenScaled": "Retain"}],
    "spec.suspend": [False],

    # --- PersistentVolumeClaim --------------------------------------------
    "spec.volumeMode": ["Filesystem"],
    "spec.volumeName": ANY,            # assigned by the PV controller on bind
    "spec.volumeClaimTemplates[].apiVersion": ["v1"],
    "spec.volumeClaimTemplates[].kind": ["PersistentVolumeClaim"],
    "spec.volumeClaimTemplates[].spec.volumeMode": ["Filesystem"],

    # --- pod spec ----------------------------------------------------------
    # imagePullPolicy is defaulted from the tag: Always for :latest,
    # IfNotPresent otherwise. Both values are defaults; any explicit choice
    # the chart cares about is declared in the template and compared above.
    "*.spec.containers[].imagePullPolicy": ["Always", "IfNotPresent"],
    "*.spec.initContainers[].imagePullPolicy": ["Always", "IfNotPresent"],
    "*.spec.containers[].terminationMessagePath": ["/dev/termination-log"],
    "*.spec.containers[].terminationMessagePolicy": ["File"],
    "*.spec.initContainers[].terminationMessagePath": ["/dev/termination-log"],
    "*.spec.initContainers[].terminationMessagePolicy": ["File"],
    "*.spec.containers[].ports[].protocol": ["TCP"],
    "*.spec.initContainers[].ports[].protocol": ["TCP"],
    "*.spec.containers[].resources": EMPTY,
    "*.spec.initContainers[].resources": EMPTY,
    "*.spec.dnsPolicy": ["ClusterFirst"],
    "*.spec.restartPolicy": ["Always"],
    "*.spec.schedulerName": ["default-scheduler"],
    "*.spec.securityContext": EMPTY,
    "*.spec.terminationGracePeriodSeconds": [30],
    # Deprecated alias the API server keeps in sync with serviceAccountName.
    "*.spec.serviceAccount": ANY,
    "*.spec.volumes[].projected.defaultMode": [420],
    "*.spec.volumes[].secret.defaultMode": [420],
    "*.spec.volumes[].configMap.defaultMode": [420],

    # --- probes ------------------------------------------------------------
    "*.httpGet.scheme": ["HTTP"],
    "*Probe.successThreshold": [1],
}

_IDX = re.compile(r"\[\d+\]")


def normalize_path(path: str) -> str:
    """Collapse list indices: spec.ports[2].protocol -> spec.ports[].protocol"""
    return _IDX.sub("[]", path)


def default_rule(path: str):
    """Return (matched_pattern, allowed) for a live-only path, or (None, None).

    A pattern may start with `*.` (matches any prefix) or end with a suffix
    form like `*Probe.successThreshold` (matches any leading segment whose last
    component ends with `Probe`). Everything else is an exact match.
    """
    p = normalize_path(path)
    allowed = SERVER_DEFAULTS.get(p)
    if allowed is not None:
        return p, allowed
    for pat, allowed in SERVER_DEFAULTS.items():
        if pat.startswith("*.") and (p.endswith(pat[1:]) or p == pat[2:]):
            return pat, allowed
        if pat.startswith("*") and not pat.startswith("*.") and p.endswith(pat[1:]):
            return pat, allowed
    return None, None


def value_allowed(allowed, value) -> bool:
    if allowed is ANY:
        return True
    if allowed is EMPTY:
        return value in ({}, [], None)
    for cand in allowed:
        # Compare as JSON so 420 / "420" and dict ordering do not matter.
        if json.dumps(cand, sort_keys=True) == json.dumps(value, sort_keys=True):
            return True
        if not isinstance(cand, (dict, list)) and str(cand) == str(value):
            return True
    return False


def leaves(path, value):
    """Flatten a render-only subtree into leaf paths."""
    if isinstance(value, dict) and value:
        for k, v in value.items():
            yield from leaves(f"{path}.{k}", v)
    else:
        yield path


def sh(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def strip(obj):
    """Drop status and per-object server bookkeeping, recursively."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in ("status", "creationTimestamp", "resourceVersion", "uid",
                     "generation", "managedFields", "selfLink"):
                continue
            out[k] = strip(v)
        ann = out.get("metadata", {}).get("annotations")
        if isinstance(ann, dict):
            for a in IGNORED_META_ANNOTATIONS:
                ann.pop(a, None)
            if not ann:
                out["metadata"].pop("annotations", None)
        return out
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj


def walk(render, live, path, mismatches, missing):
    if isinstance(render, dict):
        if not isinstance(live, dict):
            mismatches.append((path, render, live))
            return
        for k, v in render.items():
            p = f"{path}.{k}" if path else k
            if k not in live:
                missing.append((p, v))
                continue
            walk(v, live[k], p, mismatches, missing)
        return
    if isinstance(render, list):
        if not isinstance(live, list):
            mismatches.append((path, render, live))
            return
        if len(render) != len(live):
            mismatches.append((f"{path}[len]", len(render), len(live)))
            return
        for i, v in enumerate(render):
            walk(v, live[i], f"{path}[{i}]", mismatches, missing)
        return
    # Scalars: compare as strings so 8000 and "8000" do not read as drift.
    if str(render) != str(live):
        mismatches.append((path, render, live))


def live_only(render, live, path, known, unknown, extra_allow):
    """Collect live-only leaves, split into known defaults and unknown drift."""
    if isinstance(live, dict) and isinstance(render, dict):
        for k, v in live.items():
            p = f"{path}.{k}" if path else k
            if k not in render:
                pat, allowed = default_rule(p)
                if normalize_path(p) in extra_allow:
                    known.append((p, v, "--allow-live-only"))
                elif pat is not None and value_allowed(allowed, v):
                    known.append((p, v, pat))
                else:
                    unknown.append((p, v, pat))
            else:
                live_only(render[k], v, p, known, unknown, extra_allow)
    elif isinstance(live, list) and isinstance(render, list) and len(live) == len(render):
        for i, v in enumerate(live):
            live_only(render[i], v, f"{path}[{i}]", known, unknown, extra_allow)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", required=True)
    ap.add_argument("--context", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--expect-new", action="append", default=[],
                    metavar="Kind/name",
                    help="object the render adds on purpose; absence from the "
                         "cluster is not drift")
    ap.add_argument("--allow-live-only", action="append", default=[],
                    metavar="path",
                    help="one-off escape hatch: treat this normalized live-only "
                         "path as explained. Printed prominently; prefer adding "
                         "the field to the chart.")
    ap.add_argument("--verbose", action="store_true",
                    help="also print every live-only field that matched a known "
                         "API-server default")
    args = ap.parse_args()

    extra_allow = {normalize_path(p) for p in args.allow_live_only}
    if extra_allow:
        print("!! --allow-live-only in effect for: " + ", ".join(sorted(extra_allow)))

    docs = [d for d in yaml.safe_load_all(open(args.render)) if d]
    bad = 0
    for doc in docs:
        kind, name = doc["kind"], doc["metadata"]["name"]
        ns = doc["metadata"].get("namespace", args.namespace)
        try:
            raw = sh(["kubectl", "--context", args.context, "-n", ns,
                      "get", kind.lower() + "/" + name, "-o", "json"])
        except subprocess.CalledProcessError:
            if f"{kind}/{name}" in args.expect_new:
                print(f"NEW (expected)  {kind}/{name}")
                continue
            print(f"MISSING LIVE  {kind}/{name}")
            bad += 1
            continue
        live = strip(json.loads(raw))
        render = strip(doc)
        mismatches: list = []
        missing: list = []
        walk(render, live, "", mismatches, missing)
        missing = [
            (p, v) for p, v in missing
            if not all(leaf in EXPECTED_RENDER_ONLY for leaf in leaves(p, v))
        ]
        known: list = []
        unknown: list = []
        live_only(render, live, "", known, unknown, extra_allow)
        if mismatches or missing or unknown:
            bad += 1
            print(f"DRIFT  {kind}/{name}")
            for p, r, l in mismatches:
                print(f"   differs  {p}: render={r!r} live={l!r}")
            for p, v in missing:
                print(f"   render-only  {p} = {v!r}")
            for p, v, pat in unknown:
                why = ("value is not the documented default for "
                       f"{pat}" if pat else "no SERVER_DEFAULTS entry")
                print(f"   live-only, UNEXPLAINED  {p} = {v!r}  ({why})")
                print(f"       -> an operator set this and the chart cannot "
                      f"reproduce it. Add the field to the chart, or to "
                      f"SERVER_DEFAULTS if it really is an API-server default.")
        else:
            print(f"MATCH  {kind}/{name}")
        if args.verbose:
            for p, v, pat in known:
                print(f"   live-only, known default  {p}  (rule {pat})")
    print(f"\n{len(docs) - bad}/{len(docs)} objects match field for field "
          f"(or are expected additions)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
