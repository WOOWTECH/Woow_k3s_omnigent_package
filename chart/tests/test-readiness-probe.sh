#!/usr/bin/env bash
# AI-OMN-005-1 (commercial acceptance 2026-10-16): with the 10Gi /data PVC full, POST
# /auth/login answered 500 and GET /v1/sessions 401 while GET /health stayed 200 — the pod
# stayed Ready, the platform kept showing running and nobody was told. Readiness now also
# needs a real 4 KiB write + fsync on /data (liveness / startup stay GET /health: a
# restart cannot free a full volume). The rendered probe script is executed here against a
# throw-away HTTP server and data directory (/data and the port are the only substitutions).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (readiness-probe): yq (mikefarah) required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP (readiness-probe): python3 required"; exit 0; }
fail() { echo "FAIL (readiness-probe): $1"; exit 1; }
D="$(mktemp -d)"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; chmod -R u+w "$D" 2>/dev/null; rm -rf "$D"' EXIT
server() { printf '%s' "$($HELM template t "$CHART_DIR" "$@" | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="server")')"; }
S="$(server)"

# liveness / startup unchanged: GET /health on the http port
for p in livenessProbe startupProbe; do
  [ "$(printf '%s' "$S" | yq ".$p.httpGet.path")" = "/health" ] || fail "$p must stay GET /health"
done
[ "$(printf '%s' "$S" | yq '.readinessProbe.exec.command[0]')" = "python3" ] || fail "readiness must be the exec probe by default"
[ "$(printf '%s' "$S" | yq '.readinessProbe.httpGet')" = "null" ] || fail "readiness: one handler only"
[ "$(printf '%s' "$S" | yq '.readinessProbe.timeoutSeconds')" = "5" ] || fail "readiness timeout must stay the values default"
OFF="$(server --set readinessProbe.dataWritableCheck=false)"
[ "$(printf '%s' "$OFF" | yq '.readinessProbe.httpGet.path')" = "/health" ] || fail "dataWritableCheck=false must fall back to GET /health"
[ "$(printf '%s' "$OFF" | yq '.readinessProbe.exec')" = "null" ] || fail "dataWritableCheck=false: no exec probe"

printf '%s' "$S" | yq '.readinessProbe.exec.command[2]' | sed -e "s#/data/#$D/data/#g; s#\"/data\"#\"$D/data\"#g" > "$D/probe.py"
grep -q "$D/data/.woow-ready-probe" "$D/probe.py" || fail "probe file path not found in the rendered script"
mkdir "$D/data"

# a tiny /health server whose status code the test controls
cat > "$D/srv.py" <<'PY'
import http.server, sys
code_file = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = int(open(code_file).read().strip() or 200)
        self.send_response(code if self.path == "/health" else 404); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
echo 200 > "$D/code"; python3 "$D/srv.py" "$PORT" "$D/code" & SRV=$!
for _ in $(seq 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.2)" 2>/dev/null && break; sleep 0.1; done
run() { local rc=0; PORT="$PORT" HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 python3 "$D/probe.py" >"$D/out" 2>&1 || rc=$?; echo "$rc"; }
expect() { [ "$1" = "$2" ] || fail "$3 (exit $1, wanted $2): $(cat "$D/out")"; }

expect "$(run)" 0 "healthy server + writable /data → Ready (a proxy in the env must not be used for 127.0.0.1)"
[ -e "$D/data/.woow-ready-probe" ] && fail "the probe file must be removed after a good write"
echo 500 > "$D/code"; expect "$(run)" 1 "GET /health 500 → not Ready"
echo 200 > "$D/code"
ln -s /dev/full "$D/data/.woow-ready-probe"
expect "$(run)" 1 "a full volume (ENOSPC on the write) → not Ready"
grep -q 'not writable' "$D/out" || fail "the probe must say the volume is not writable: $(cat "$D/out")"
rm -f "$D/data/.woow-ready-probe"; expect "$(run)" 0 "space freed → Ready again"
chmod 555 "$D/data"
if [ "$(id -u)" != 0 ]; then expect "$(run)" 1 "a read-only /data → not Ready"; fi
chmod 755 "$D/data"
kill "$SRV"; wait "$SRV" 2>/dev/null || true; SRV=""
expect "$(run)" 1 "server not answering → not Ready"
echo "PASS (readiness-probe): readiness = GET /health AND a 4 KiB write + fsync on /data (full / read-only volume → not Ready, AI-OMN-005-1); liveness / startup stay GET /health; dataWritableCheck=false falls back"
