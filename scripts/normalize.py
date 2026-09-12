#!/usr/bin/env python3
"""Field-by-field comparison of a rendered chart against the live objects.

Direction matters. For every field the chart DECLARES we require the live
object to carry the same value; fields that exist only in the live object are
either server-side defaults or controller bookkeeping and are listed separately
so nothing is hidden.

  python3 scripts/normalize.py --render /tmp/repo.yaml \
      --context woow-k3s --namespace omnigent

Exit 0 when every declared field matches (ignoring the documented
render-only set), 1 otherwise. Read-only: `kubectl get` and nothing else.
"""
from __future__ import annotations

import argparse
import json
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


def flat_live_only(render, live, path, out):
    if isinstance(live, dict) and isinstance(render, dict):
        for k, v in live.items():
            p = f"{path}.{k}" if path else k
            if k not in render:
                out.append(p)
            else:
                flat_live_only(render[k], v, p, out)
    elif isinstance(live, list) and isinstance(render, list) and len(live) == len(render):
        for i, v in enumerate(live):
            flat_live_only(render[i], v, f"{path}[{i}]", out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", required=True)
    ap.add_argument("--context", required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--expect-new", action="append", default=[],
                    metavar="Kind/name",
                    help="object the render adds on purpose; absence from the "
                         "cluster is not drift")
    ap.add_argument("--verbose", action="store_true",
                    help="also print every live-only field (server defaults)")
    args = ap.parse_args()

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
        if mismatches or missing:
            bad += 1
            print(f"DRIFT  {kind}/{name}")
            for p, r, l in mismatches:
                print(f"   differs  {p}: render={r!r} live={l!r}")
            for p, v in missing:
                print(f"   render-only  {p} = {v!r}")
        else:
            print(f"MATCH  {kind}/{name}")
        if args.verbose:
            only: list = []
            flat_live_only(render, live, "", only)
            for p in only:
                print(f"   live-only (server default)  {p}")
    print(f"\n{len(docs) - bad}/{len(docs)} objects match field for field "
          f"(or are expected additions)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
