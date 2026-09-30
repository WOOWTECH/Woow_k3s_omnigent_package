#!/usr/bin/env bash
# Sync this mirror from the Gitea source of truth.
#
# This repository is a read-only MIRROR of the WOOW PaaS omnigent cloud
# service. The authoritative copy lives on the internal Gitea
# (git-prod.woowtech.io); edits made here are overwritten by the next sync.
#
#   chart/    <- woow-paas/woow-paas-charts  charts/omnigent/
#
# omnigent ships no WOOW-built image: the server and runner images are the
# upstream ghcr.io images copied byte-for-byte into jcr-prod (paas-odoo-ci
# mirror-image.yml), so only the chart is mirrored. The image pins are read
# from chart/values.yaml into MIRROR.md.
#
# Usage:  scripts/sync-from-gitea.sh [woow-paas-charts-ref]   (default "main")
#
# Needs git read access to the Gitea repo (e.g. a credential helper for
# https://git-prod.woowtech.io). Writes the resolved commit into MIRROR.md so
# every mirrored file can be traced back to the exact source revision.
set -Eeuo pipefail

GITEA="${GITEA_URL:-https://git-prod.woowtech.io}"
CHARTS_REF="${1:-main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/charts"
git -C "$WORK/charts" fetch -q --depth 1 "$GITEA/woow-paas/woow-paas-charts.git" "$CHARTS_REF"
git -C "$WORK/charts" checkout -q FETCH_HEAD
CHARTS_SHA="$(git -C "$WORK/charts" rev-parse HEAD)"

SRC="$WORK/charts/charts/omnigent"
[ -d "$SRC" ] || { echo "missing source directory: charts/omnigent" >&2; exit 1; }
rm -rf "$ROOT/chart"
mkdir -p "$ROOT/chart"
cp -a "$SRC/." "$ROOT/chart/"

CHART_VERSION="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml")"
APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$ROOT/chart/Chart.yaml")"

# Rewrite only the generated block of MIRROR.md; the prose around it is kept.
python3 - "$ROOT/MIRROR.md" "$ROOT/chart/values.yaml" "$CHARTS_SHA" "$CHART_VERSION" "$APP_VERSION" <<'PY'
import sys, re, datetime
path, values_path, charts, chart_ver, app_ver = sys.argv[1:6]
values = open(values_path, encoding="utf-8").read()
repo = re.search(r'^  repository: (\S+)', values, re.M).group(1)
tag = re.search(r'^  tag: "([^"]+)"', values, re.M).group(1)
host = re.search(r'^  image: "([^"]+)"', values, re.M).group(1)
block = (
    "<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->\n"
    "| Mirror path | Source repository | Source path | Commit |\n"
    "|---|---|---|---|\n"
    f"| `chart/` | `woow-paas/woow-paas-charts` | `charts/omnigent/` | `{charts}` |\n"
    "\n"
    "| Image | Pinned reference (chart default = platform pin) |\n"
    "|---|---|\n"
    f"| server | `{repo}:{tag}` |\n"
    f"| runner (managed sandbox) | `{host}` |\n"
    "\n"
    f"Chart `{chart_ver}` / omnigent `{app_ver}` — synced "
    f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC.\n"
    "<!-- END GENERATED -->"
)
text = open(path, encoding="utf-8").read()
new, n = re.subn(r"<!-- BEGIN GENERATED.*?<!-- END GENERATED -->", block, text, flags=re.S)
if n != 1:
    sys.exit("MIRROR.md is missing its generated block markers")
open(path, "w", encoding="utf-8").write(new)
PY

echo "synced: woow-paas-charts@${CHARTS_SHA:0:8}  chart ${CHART_VERSION} / omnigent ${APP_VERSION}"
