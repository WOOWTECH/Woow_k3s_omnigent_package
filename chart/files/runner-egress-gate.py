# Runner egress gate (woow_paas_platform #1497). Runs from BASH_ENV in both runner
# containers (see values.yaml runner.egressGate): blocks until this Pod's
# NetworkPolicy is observed — the probe target (default: the kubernetes Service,
# which the runner policy and the platform baseline both deny) is refused or times
# out twice in a row — then writes a marker in the shared HOME so later shells skip.
# Same semantics as paas-operator's `woow-egress-gate` init container. stdout MUST
# stay empty: it is the BASH_ENV expansion (a non-empty one would be sourced).
import os
import socket
import sys
import time


def log(msg):
    sys.stderr.write("egress-gate: %s\n" % msg)
    sys.stderr.flush()


def mark(path):
    try:
        with open(path, "a"):
            pass
    except OSError as exc:
        log("cannot write marker %s: %s" % (path, exc))


def main():
    env = os.environ
    marker = env.get("WOOW_EGRESS_GATE_MARKER") or "/home/omnigent/.woow-egress-gate"
    target = env.get("WOOW_EGRESS_GATE_TARGET") or "%s:%s" % (
        env.get("KUBERNETES_SERVICE_HOST") or "10.43.0.1",
        env.get("KUBERNETES_SERVICE_PORT") or "443",
    )
    host, _, port = target.rpartition(":")
    host = host.strip("[]")
    try:
        timeout = int(env.get("WOOW_EGRESS_GATE_TIMEOUT") or 60)
        need = int(env.get("WOOW_EGRESS_GATE_CONSECUTIVE") or 2)
        port = int(port)
    except ValueError:
        log("bad configuration (target %r) — proceeding" % target)
        return
    start = time.monotonic()
    blocked = probes = 0
    while True:
        probes += 1
        try:
            socket.create_connection((host, port), timeout=1).close()
            blocked = 0
        except OSError:
            blocked += 1
        elapsed = time.monotonic() - start
        if blocked >= need:
            log("policy active (target %s blocked x%d, probes=%d, %.1fs)" % (target, blocked, probes, elapsed))
            mark(marker)
            return
        if elapsed >= timeout:
            break
        time.sleep(0.2)
    log("policy NOT observed within %ds (target %s, probes=%d)" % (timeout, target, probes))
    log("proceeding (on_timeout=proceed)")
    mark(marker)


try:
    main()
except Exception as exc:  # never keep a runner from starting because of the gate itself
    log("internal error %r — proceeding" % (exc,))
