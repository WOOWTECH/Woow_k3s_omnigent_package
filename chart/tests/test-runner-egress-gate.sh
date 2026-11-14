#!/usr/bin/env bash
# Runner egress gate (woow_paas_platform #1497, commercial acceptance netpol-startup-window).
#
# k3s kube-router programs a NEW pod's NetworkPolicy rules only after the pod is
# already running, so for the first ~1–3 s its egress is unrestricted. paas-operator
# closes that window for helm-rendered pods with a `woow-egress-gate` init container
# (post-renderer, woow_paas_platform #1778) — but Omnigent runner Pods are built at
# RUNTIME by upstream's kubernetes launcher (the server creates a Job through the k8s
# API), never pass through helm, and upstream has no init-container / pod-template
# hook. Both runner containers (workspace-prep, which `git clone`s tenant-chosen
# URLs, and the host) start as `bash -lc …` with envFrom the runner env Secret this
# chart owns. So the chart puts BASH_ENV (+ the gate program) into that Secret: bash
# expands BASH_ENV before running the -c string, and the expansion runs the gate,
# which blocks until the policy is observed (the probe target is refused / times out
# twice in a row) and leaves a marker in the shared HOME emptyDir so later shells
# (the host container, every `bash -c` the agent runs) skip it.
#
# This suite checks the render contract AND executes the rendered BASH_ENV + gate
# against a local fake target that "gets blocked" after a delay (window analog).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (runner-egress-gate): yq (mikefarah) required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP (runner-egress-gate): python3 required"; exit 0; }
fail() { echo "FAIL (runner-egress-gate): $1"; exit 1; }
TMP="$(mktemp -d)"; LPID=""
cleanup() { [ -n "$LPID" ] && kill "$LPID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

renv() {  # renv KEY [helm args…] → decoded value of KEY in the runner env Secret ("" if absent)
  local key="$1"; shift
  $HELM template t "$CHART_DIR" "$@" | yq -N "select(.kind==\"Secret\" and .metadata.name==\"t-omnigent-runner-env\") | .data[\"$key\"] // \"\"" | { base64 -d 2>/dev/null || true; }
}

# ── render contract ──────────────────────────────────────────────────────────
BASH_ENV_VAL="$(renv BASH_ENV)"
GATE_PY="$(renv WOOW_EGRESS_GATE_PY)"
MARKER_DEFAULT="$(renv WOOW_EGRESS_GATE_MARKER)"
[ -n "$BASH_ENV_VAL" ] || fail "runner env Secret must carry BASH_ENV by default (runner.egressGate.enabled)"
[ -n "$GATE_PY" ] || fail "runner env Secret must carry the gate program WOOW_EGRESS_GATE_PY"
[ "$MARKER_DEFAULT" = "/home/omnigent/.woow-egress-gate" ] || fail "marker must live in the runner HOME emptyDir shared by init + host (got '$MARKER_DEFAULT')"
[ "$(renv WOOW_EGRESS_GATE_TIMEOUT)" = "60" ] || fail "default gate timeout 60 s"
[ -z "$(renv WOOW_EGRESS_GATE_TARGET)" ] || fail "default target = KUBERNETES_SERVICE_HOST:PORT (no explicit WOOW_EGRESS_GATE_TARGET)"
[ "$(renv WOOW_EGRESS_GATE_TARGET --set runner.egressGate.target=10.43.0.1:443)" = "10.43.0.1:443" ] || fail "runner.egressGate.target not honoured"
[ "$(renv WOOW_EGRESS_GATE_TIMEOUT --set runner.egressGate.timeoutSeconds=20)" = "20" ] || fail "runner.egressGate.timeoutSeconds not honoured"
python3 -c 'import ast,sys; ast.parse(sys.stdin.read())' <<<"$GATE_PY" || fail "gate program is not valid Python"
# Off switches: the gate only makes sense while a runner NetworkPolicy exists (without
# one the probe never gets blocked and every runner would wait the full timeout).
for args in "--set runner.egressGate.enabled=false" "--set networkPolicy.runner.enabled=false" "--set networkPolicy.enabled=false"; do
  # shellcheck disable=SC2086
  for key in BASH_ENV WOOW_EGRESS_GATE_PY WOOW_EGRESS_GATE_MARKER WOOW_EGRESS_GATE_TIMEOUT; do
    [ -z "$(renv "$key" $args)" ] || fail "$args must drop $key from the runner env Secret"
  done
done
# Reserved keys cannot be overridden (or the gate disabled) through runner.env.
for key in BASH_ENV WOOW_EGRESS_GATE_PY WOOW_EGRESS_GATE_MARKER; do
  if $HELM template t "$CHART_DIR" --set "runner.env.$key=x" >/dev/null 2>&1; then fail "runner.env.$key must be rejected (reserved for the egress gate)"; fi
done
if $HELM template t "$CHART_DIR" --set runner.egressGate.timeoutSeconds=0 >/dev/null 2>&1; then fail "timeoutSeconds=0 must be rejected"; fi
if $HELM template t "$CHART_DIR" --set 'runner.egressGate.target=a b' >/dev/null 2>&1; then fail "a malformed target must be rejected"; fi
# The rendered Job spec is upstream's: nothing in the server config may change for the gate.
[ "$($HELM template t "$CHART_DIR" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-omnigent-config") | .data["config.yaml"]' | sha256sum)" = \
  "$($HELM template t "$CHART_DIR" --set runner.egressGate.enabled=false | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-omnigent-config") | .data["config.yaml"]' | sha256sum)" ] \
  || fail "the gate must not change the server's sandbox config (it rides only on the runner env Secret)"

# ── behaviour: execute the rendered BASH_ENV + gate ──────────────────────────
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
# Fake "policy": the target accepts connections for OPEN_FOR seconds (window still
# open), then stops listening (connection refused == egress blocked).
listen() {  # listen SECONDS (0 = forever)
  python3 - "$PORT" "$1" <<'PY' &
import socket, sys, time
port, open_for = int(sys.argv[1]), float(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(64); s.settimeout(0.05)
t0 = time.time()
while open_for == 0 or time.time() - t0 < open_for:
    try:
        c, _ = s.accept(); c.close()
    except OSError:
        pass
s.close()
time.sleep(3600)
PY
  LPID=$!
  for _ in $(seq 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.2).close()" 2>/dev/null && return 0; sleep 0.05; done
  fail "fake target did not come up"
}
stop_listen() { kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true; LPID=""; }
# What the tenant's first command sees: can it reach the target right away?
PROBE='python3 -c "import socket,sys
try:
    socket.create_connection((\"127.0.0.1\",'"$PORT"'),0.5).close(); print(\"OPEN\")
except OSError:
    print(\"BLOCKED\")"'
run_runner() {  # run_runner GATE(0/1) CMD — mimic a runner container: bash -lc with envFrom the Secret
  local gate="$1" cmd="$2"
  if [ "$gate" = 1 ]; then
    env -i PATH="$PATH" HOME="$TMP/home" KUBERNETES_SERVICE_HOST=192.0.2.1 KUBERNETES_SERVICE_PORT=443 \
      BASH_ENV="$BASH_ENV_VAL" WOOW_EGRESS_GATE_PY="$GATE_PY" WOOW_EGRESS_GATE_MARKER="$TMP/home/.woow-egress-gate" \
      WOOW_EGRESS_GATE_TIMEOUT="${GATE_TIMEOUT:-20}" WOOW_EGRESS_GATE_TARGET="127.0.0.1:$PORT" \
      bash -lc "$cmd"
  else
    env -i PATH="$PATH" HOME="$TMP/home" bash -lc "$cmd"
  fi
}
mkdir -p "$TMP/home"

# 1. control (no gate): the first command reaches the target inside the window.
listen 1.5
[ "$(run_runner 0 "$PROBE" 2>/dev/null)" = "OPEN" ] || fail "control: without the gate the window must be observable (first probe OPEN)"
stop_listen

# 2. gate: the -c command only starts once the target is blocked; the gate logs to
#    stderr only (stdout = BASH_ENV's expansion must stay empty) and writes the marker.
rm -f "$TMP/home/.woow-egress-gate"; listen 1.5
t0=$(date +%s.%N)
run_runner 1 "$PROBE" >"$TMP/out" 2>"$TMP/err" || fail "gated shell exited non-zero: $(cat "$TMP/err")"
t1=$(date +%s.%N)
[ "$(cat "$TMP/out")" = "BLOCKED" ] || fail "gate: the first tenant command must already see the target blocked (got '$(cat "$TMP/out")'; stderr: $(cat "$TMP/err"))"
grep -q "egress-gate: policy active" "$TMP/err" || fail "gate must log 'policy active' to stderr: $(cat "$TMP/err")"
python3 -c "import sys; sys.exit(0 if $t1 - $t0 >= 1.4 else 1)" || fail "gate returned before the window closed"
[ -e "$TMP/home/.woow-egress-gate" ] || fail "gate must leave its marker in HOME"
grep -qiE "no such file|bad substitution|syntax error" "$TMP/err" && fail "BASH_ENV expansion must be clean: $(cat "$TMP/err")"
stop_listen

# 3. later shells (host container after workspace-prep, nested `bash -c` from the agent)
#    see the marker and skip the gate: no probe, no log line, no delay.
listen 0
run_runner 1 'bash -c "bash -c true"; echo ok' >"$TMP/out" 2>"$TMP/err"
[ "$(cat "$TMP/out")" = "ok" ] || fail "nested shells must still work"
[ ! -s "$TMP/err" ] || fail "with the marker present no shell may run the gate again: $(cat "$TMP/err")"
stop_listen

# 4. timeout → proceed (CNI broken / no policy): logs NOT observed, still runs, marks.
rm -f "$TMP/home/.woow-egress-gate"; listen 0
GATE_TIMEOUT=2 run_runner 1 'echo ran' >"$TMP/out" 2>"$TMP/err"
[ "$(cat "$TMP/out")" = "ran" ] || fail "timeout must proceed (on_timeout=proceed)"
grep -q "policy NOT observed within 2s" "$TMP/err" || fail "timeout must be logged: $(cat "$TMP/err")"
[ -e "$TMP/home/.woow-egress-gate" ] || fail "timeout must still write the marker (no 2nd full wait in the host container)"
stop_listen

# 5. a probe target that is unreachable from the start (policy already active) costs ~2 probes.
rm -f "$TMP/home/.woow-egress-gate"
t0=$(date +%s.%N); run_runner 1 'true' 2>"$TMP/err"; t1=$(date +%s.%N)
python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 5 else 1)" || fail "already-blocked target must pass the gate quickly"
grep -q "blocked x2" "$TMP/err" || fail "gate needs 2 consecutive blocked probes: $(cat "$TMP/err")"

echo "PASS (runner-egress-gate): BASH_ENV + gate program in the runner env Secret (default on, off without a runner NetworkPolicy, reserved keys), server sandbox config untouched; gated runner shell waits out the window (first command sees the target blocked), logs to stderr only, marker skips later/nested shells, timeout proceeds and marks."
