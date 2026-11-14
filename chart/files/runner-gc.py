"""runner-gc: tie this release's managed-sandbox runner Jobs to the release.

Upstream's kubernetes sandbox launcher (omnigent v0.16.0, unchanged through v0.19.1) creates every runner
as a bare batch/v1 Job: labels app.kubernetes.io/managed-by=omnigent +
omnigent.ai/role=sandbox-host only, NO ownerReferences, activeDeadlineSeconds
7 days — and `sandbox.kubernetes` accepts no extra labels / owner / deadline
keys (unknown keys are rejected). So `helm uninstall` leaves running runners
behind for up to 7 days (#1349).

This loop adopts them: every Job that runs as THIS release's runner
ServiceAccount (the only release-specific field upstream stamps on the Job)
gets an ownerReference to that ServiceAccount. `helm uninstall` deletes the
ServiceAccount, and the Kubernetes garbage collector then deletes the Jobs and
their Pods — no pre-delete hook, so nothing extra has to schedule, pull or fit
the workspace ResourceQuota at uninstall time.

#1536: it ALSO enforces an optional hard age cap on this release's runner Jobs.
keep_warm_s (runner.idle_timeout_s) only drains the INNER runner process once a
session is idle; the host Job itself (holding the runner's CPU/RAM request) is
reclaimed by the server only on session delete, by its 7-day activeDeadlineSeconds,
or by the 30-day offline reaper — the Kubernetes provider has no idle-stop. An
idle-but-connected host therefore holds its quota for up to 7 days. Upstream
hardcodes activeDeadlineSeconds and rejects a config override, so when
MAX_JOB_AGE_SECONDS is set (runner.gc.maxJobAgeSeconds > 0) this loop deletes a
runner Job once it is older than that — a hard lifetime cap SHORTER than 7 days,
NOT an idle timer: a legitimately active session past the cap is ended too, so
set it above the longest session a tenant is expected to run. 0 (default) keeps
the upstream 7-day behaviour. Real idle-reclaim is server-side (see the issue).

AI-FIX-OMN-1-1: it ALSO reaps orphaned runner token Secrets. The launcher creates
a per-Job Secret `<job>-token` (labels managed-by=omnigent + role=sandbox-host, NO
ownerReferences) before each Job and deletes it only from its own terminate() and
start-failure paths. Every other way a runner Job goes away leaves the Secret
behind forever: ttlSecondsAfterFinished (the cluster deletes a Job 24 h after it
ends on its own — backoff exhausted, 7-day deadline), the runner-SA ownerReference
cascade above, this loop's own max-age delete, a terminate() whose Secret delete
failed. So the loop remembers the names of this release's runner Jobs it has seen
(STATE_FILE on the pod's /tmp emptyDir, so a sidecar restart keeps it) and deletes
`<name>-token` once that Job has been GONE for TOKEN_SECRET_GRACE_SECONDS (never
less than two ticks). The grace covers resume(): it deletes a dormant Job + Secret
and immediately recreates both under the same name — a Job seen again resets the
timer, and a reaped name is forgotten, so a later fresh Secret is never touched.
This uses only the `secrets: delete` verb the launcher already needs: secrets
list/get/patch would let a leaked server token read every Secret in the namespace,
so Secrets whose Job vanished while no runner-gc was running (e.g. during a pod
replacement, or before this version) cannot be discovered here.

Best effort by design: any API error is logged and retried next tick; the loop
never exits on its own (a crash would only restart the sidecar).
"""

import datetime
import json
import logging
import os
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s runner-gc %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("runner-gc")

NAMESPACE = os.environ["NAMESPACE"]
RUNNER_SA = os.environ["RUNNER_SERVICE_ACCOUNT"]
INTERVAL_S = max(5, int(os.environ.get("INTERVAL_SECONDS", "15")))
# #1536: hard age cap (seconds) for this release's runner Jobs. 0/unset = off.
MAX_JOB_AGE_S = max(0, int(os.environ.get("MAX_JOB_AGE_SECONDS", "0")))
# AI-FIX-OMN-1-1: reap `<job>-token` Secrets of runner Jobs that are gone.
REAP_TOKENS = os.environ.get("REAP_TOKEN_SECRETS", "1") not in ("0", "false", "False", "")
# Floor of two ticks: a resume() recreates the Job within the same second.
TOKEN_GRACE_S = max(2 * INTERVAL_S, int(os.environ.get("TOKEN_SECRET_GRACE_SECONDS", "120")))
STATE_FILE = os.environ.get("STATE_FILE", "")
SELECTOR = "app.kubernetes.io/managed-by=omnigent,omnigent.ai/role=sandbox-host"
TIMEOUT_S = 10


def _ref_dict(ref):
    """Serialize an existing V1OwnerReference back to its API (camelCase) form."""
    out = {"apiVersion": ref.api_version, "kind": ref.kind, "name": ref.name, "uid": ref.uid}
    if ref.controller is not None:
        out["controller"] = ref.controller
    if ref.block_owner_deletion is not None:
        out["blockOwnerDeletion"] = ref.block_owner_deletion
    return out


def _too_old(job, now):
    """True when MAX_JOB_AGE_S is set and the Job has existed longer than it."""
    if MAX_JOB_AGE_S <= 0:
        return False
    created = job.metadata.creation_timestamp
    if created is None:
        return False
    return (now - created).total_seconds() > MAX_JOB_AGE_S


def _token_secret_name(job_name):
    """The launcher's per-Job token Secret name (upstream _token_secret_name)."""
    return f"{job_name}-token"


def load_state():
    """Tracked runner Job names → epoch seconds first seen missing (None = present)."""
    if not STATE_FILE:
        return {}
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(k): (float(v) if isinstance(v, (int, float)) else None)
        for k, v in data.items()
    }


def save_state(state):
    """Persist the tracking state (best effort; atomic rename)."""
    if not STATE_FILE:
        return
    tmp = f"{STATE_FILE}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as exc:
        log.warning("could not save state to %s: %s", STATE_FILE, exc)


def _delete_token_secret(core, job_name):
    """Delete `<job>-token`. True when it is gone (deleted or 404), False to retry."""
    name = _token_secret_name(job_name)
    try:
        core.delete_namespaced_secret(name, NAMESPACE, _request_timeout=TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001 — ApiException / transport error
        if getattr(exc, "status", None) == 404:
            return True
        log.warning("could not delete token Secret %s (retrying next tick): %s", name, exc)
        return False
    log.info("deleted token Secret %s (runner Job %s is gone)", name, job_name)
    return True


def _reap_tokens(core, state, present, now_s):
    """Delete the token Secret of every tracked Job gone for longer than the grace."""
    for name in present:
        state[name] = None
    for name in list(state):
        if name in present:
            continue
        missing_since = state[name]
        if missing_since is None:
            state[name] = now_s
            continue
        if now_s - missing_since < TOKEN_GRACE_S:
            continue
        if _delete_token_secret(core, name):
            del state[name]


def reconcile(core, batch, state=None, now_s=None):
    """Adopt every un-owned runner Job of this release. Returns the adopted names.

    With *state* (see load_state) it also reaps the token Secrets of this
    release's runner Jobs that have disappeared (AI-FIX-OMN-1-1).
    """
    if now_s is None:
        now_s = time.time()
    sa = core.read_namespaced_service_account(RUNNER_SA, NAMESPACE, _request_timeout=TIMEOUT_S)
    owner_uid = sa.metadata.uid
    owner = {"apiVersion": "v1", "kind": "ServiceAccount", "name": RUNNER_SA, "uid": owner_uid}
    adopted = []
    present = set()
    now = datetime.datetime.now(datetime.timezone.utc)
    jobs = batch.list_namespaced_job(NAMESPACE, label_selector=SELECTOR, _request_timeout=TIMEOUT_S)
    for job in jobs.items:
        pod_spec = job.spec.template.spec if job.spec and job.spec.template else None
        # Another omnigent release in the same workspace namespace launches its
        # runners as ITS runner SA — never touch those.
        if pod_spec is None or (pod_spec.service_account_name or "") != RUNNER_SA:
            continue
        # A Job that still exists (even mid-delete) keeps its token Secret.
        present.add(job.metadata.name)
        if job.metadata.deletion_timestamp is not None:
            continue
        # #1536: hard age cap — delete (cascade to the Pod) past MAX_JOB_AGE_S.
        if _too_old(job, now):
            log.info(
                "deleting runner Job %s past max age %ss (created %s)",
                job.metadata.name, MAX_JOB_AGE_S, job.metadata.creation_timestamp,
            )
            batch.delete_namespaced_job(
                job.metadata.name, NAMESPACE,
                propagation_policy="Foreground", _request_timeout=TIMEOUT_S,
            )
            # AI-FIX-OMN-1-1: this path never ran the launcher's terminate(), so
            # the token Secret would be left behind — delete it now (the running
            # container already resolved its secretKeyRef). On failure the name
            # stays tracked and the reaper retries once the Job is gone.
            if REAP_TOKENS and _delete_token_secret(core, job.metadata.name):
                present.discard(job.metadata.name)
                if state is not None:
                    state.pop(job.metadata.name, None)
            continue
        refs = job.metadata.owner_references or []
        if any(r.uid == owner_uid for r in refs):
            continue
        body = {
            "metadata": {
                # Optimistic concurrency: a concurrent writer makes this a 409,
                # retried next tick instead of clobbering its ownerReferences.
                "resourceVersion": job.metadata.resource_version,
                # blockOwnerDeletion stays unset: it would need delete rights on
                # the ServiceAccount, and uninstall must never wait on runners.
                "ownerReferences": [_ref_dict(r) for r in refs] + [owner],
            }
        }
        batch.patch_namespaced_job(
            job.metadata.name,
            NAMESPACE,
            body,
            _content_type="application/merge-patch+json",
            _request_timeout=TIMEOUT_S,
        )
        adopted.append(job.metadata.name)
    if REAP_TOKENS and state is not None:
        _reap_tokens(core, state, present, now_s)
    return adopted


def main():
    from kubernetes import client, config

    config.load_incluster_config()
    core = client.CoreV1Api()
    batch = client.BatchV1Api()
    log.info("watching runner Jobs of serviceAccount %s in %s every %ss", RUNNER_SA, NAMESPACE, INTERVAL_S)
    state = load_state()
    if REAP_TOKENS:
        log.info("reaping token Secrets of runner Jobs gone for %ss", TOKEN_GRACE_S)
    while True:
        try:
            for name in reconcile(core, batch, state=state):
                log.info("adopted runner Job %s (owner: serviceaccount/%s)", name, RUNNER_SA)
        except Exception as exc:  # noqa: BLE001 — best effort, retried next tick
            log.warning("reconcile failed (retrying in %ss): %s", INTERVAL_S, exc)
        save_state(state)
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    main()
