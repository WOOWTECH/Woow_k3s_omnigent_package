"""Unit checks for the runner-gc token-Secret reaper (AI-FIX-OMN-1-1).

Run by test-runner-gc-token-secrets.sh against the runner-gc.py that helm
actually renders into the ConfigMap (path in argv[1]). No kubernetes SDK or
cluster needed: the script only touches the API through the client objects
passed into reconcile(), so plain fakes stand in for CoreV1Api / BatchV1Api.

Upstream (omnigent v0.17 kubernetes launcher) creates a per-Job Secret
``<job>-token`` (labels managed-by=omnigent + role=sandbox-host, NO
ownerReferences) before each runner Job, and deletes it only from its own
terminate()/start-failure paths. Every other way a runner Job disappears —
ttlSecondsAfterFinished (24 h after the Job ends on its own), the runner-SA
ownerReference cascade, runner-gc's own max-age delete, a terminate() whose
Secret delete failed — leaves the token Secret behind forever.
"""

import datetime
import importlib.util
import json
import os
import sys
import tempfile
from types import SimpleNamespace as NS

SCRIPT = sys.argv[1]
RUNNER_SA = "svc-aaaa1111-omnigent-runner"
OTHER_SA = "svc-bbbb2222-omnigent-runner"
# Real wall clock: runner-gc judges Job age against datetime.now().
NOW = datetime.datetime.now(datetime.timezone.utc)
FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print(f"  not ok - {msg}")
    else:
        print(f"  ok - {msg}")


def load(**env):
    base = {
        "NAMESPACE": "paas-ws-test",
        "RUNNER_SERVICE_ACCOUNT": RUNNER_SA,
        "INTERVAL_SECONDS": "15",
        "MAX_JOB_AGE_SECONDS": "0",
        "TOKEN_SECRET_GRACE_SECONDS": "120",
        "REAP_TOKEN_SECRETS": "1",
        "STATE_FILE": "",
    }
    base.update(env)
    for k, v in base.items():
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location("runner_gc_under_test", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ApiError(Exception):
    def __init__(self, status):
        super().__init__(f"HTTP {status}")
        self.status = status


def job(name, sa=RUNNER_SA, age_s=60, deleting=False, owned=False):
    refs = [NS(api_version="v1", kind="ServiceAccount", name=RUNNER_SA, uid="sa-uid",
               controller=None, block_owner_deletion=None)] if owned else None
    return NS(
        metadata=NS(name=name, creation_timestamp=NOW - datetime.timedelta(seconds=age_s),
                    deletion_timestamp=NOW if deleting else None,
                    owner_references=refs, resource_version="1"),
        spec=NS(template=NS(spec=NS(service_account_name=sa))),
    )


class Batch:
    def __init__(self):
        self.jobs = []
        self.deleted = []

    def list_namespaced_job(self, ns, label_selector=None, _request_timeout=None):
        return NS(items=list(self.jobs))

    def delete_namespaced_job(self, name, ns, propagation_policy=None, _request_timeout=None):
        self.deleted.append(name)

    def patch_namespaced_job(self, name, ns, body, _content_type=None, _request_timeout=None):
        pass


class Core:
    def __init__(self):
        self.deleted = []
        self.fail = {}

    def read_namespaced_service_account(self, name, ns, _request_timeout=None):
        return NS(metadata=NS(uid="sa-uid"))

    def delete_namespaced_secret(self, name, ns, _request_timeout=None, **kw):
        if name in self.fail:
            raise ApiError(self.fail[name])
        self.deleted.append(name)


def run(mod, core, batch, state, t):
    return mod.reconcile(core, batch, state=state, now_s=t)


print("# 1. Job seen, then gone (TTL / SA cascade / external delete): token reaped after grace")
mod = load()
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-a1-000001")]
run(mod, core, batch, st, 1000.0)
batch.jobs = []
run(mod, core, batch, st, 1015.0)
check(core.deleted == [], "no Secret delete before the grace period (resume window)")
run(mod, core, batch, st, 1015.0 + 121)
check(core.deleted == ["omnigent-managed-a1-000001-token"],
      f"token Secret <job>-token deleted once the Job stays gone past grace (got {core.deleted})")
run(mod, core, batch, st, 1015.0 + 500)
check(core.deleted == ["omnigent-managed-a1-000001-token"], "reaped name is forgotten (no repeat delete)")

print("# 2. resume(): Job deleted and recreated under the same name inside grace → Secret kept")
mod = load()
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-r1-000001")]
run(mod, core, batch, st, 0.0)
batch.jobs = []
run(mod, core, batch, st, 15.0)
batch.jobs = [job("omnigent-managed-r1-000001", age_s=1)]
run(mod, core, batch, st, 30.0)
run(mod, core, batch, st, 400.0)
check(core.deleted == [], "recreated Job resets the missing timer (fresh token Secret untouched)")

print("# 3. runner-gc's own max-age delete also removes the token Secret")
mod = load(MAX_JOB_AGE_SECONDS="3600")
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-old-000001", age_s=7200)]
run(mod, core, batch, st, 0.0)
check(batch.deleted == ["omnigent-managed-old-000001"], "over-age Job deleted (existing #1536 behaviour)")
check(core.deleted == ["omnigent-managed-old-000001-token"],
      f"its token Secret deleted in the same tick (got {core.deleted})")

print("# 4. another release's runner Jobs (other SA) are never reaped")
mod = load()
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-x-000001", sa=OTHER_SA)]
run(mod, core, batch, st, 0.0)
batch.jobs = []
run(mod, core, batch, st, 1000.0)
check(core.deleted == [], "other release's token Secret untouched")

print("# 5. Job still terminating (deletionTimestamp) counts as present")
mod = load()
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-t-000001")]
run(mod, core, batch, st, 0.0)
batch.jobs = [job("omnigent-managed-t-000001", deleting=True)]
run(mod, core, batch, st, 500.0)
check(core.deleted == [], "terminating Job's Secret kept while the Job object exists")

print("# 6. 404 → done; 403/500 → retried next tick, never breaks adoption")
mod = load()
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-g-000001"), job("omnigent-managed-f-000001")]
run(mod, core, batch, st, 0.0)
batch.jobs = []
core.fail = {"omnigent-managed-g-000001-token": 404, "omnigent-managed-f-000001-token": 403}
run(mod, core, batch, st, 1.0)
try:
    run(mod, core, batch, st, 200.0)
    raised = False
except Exception:  # noqa: BLE001
    raised = True
check(not raised, "a failed Secret delete does not raise out of reconcile()")
core.fail = {}
batch.jobs = [job("omnigent-managed-new-000001")]
run(mod, core, batch, st, 230.0)
check(core.deleted == ["omnigent-managed-f-000001-token"],
      f"403 is retried next tick, 404 is not (got {core.deleted})")

print("# 7. state survives a sidecar restart (STATE_FILE on the pod's emptyDir)")
with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "state.json")
    mod = load(STATE_FILE=path)
    core, batch = Core(), Batch()
    st = mod.load_state()
    batch.jobs = [job("omnigent-managed-s-000001")]
    run(mod, core, batch, st, 0.0)
    mod.save_state(st)
    check(os.path.exists(path) and "omnigent-managed-s-000001" in json.load(open(path)),
          "state file written with tracked Job names")
    mod2 = load(STATE_FILE=path)
    st2 = mod2.load_state()
    batch.jobs = []
    run(mod2, core, batch, st2, 10.0)
    run(mod2, core, batch, st2, 200.0)
    check(core.deleted == ["omnigent-managed-s-000001-token"],
          "a Job that vanished across a container restart is still reaped")
    with open(path, "w") as fh:
        fh.write("{not json")
    check(load(STATE_FILE=path).load_state() == {}, "corrupt state file → empty state, no crash")

print("# 8. REAP_TOKEN_SECRETS=0 turns the reaper off")
mod = load(REAP_TOKEN_SECRETS="0", MAX_JOB_AGE_SECONDS="3600")
core, batch, st = Core(), Batch(), {}
batch.jobs = [job("omnigent-managed-o-000001"), job("omnigent-managed-old-000002", age_s=7200)]
run(mod, core, batch, st, 0.0)
batch.jobs = []
run(mod, core, batch, st, 1000.0)
check(core.deleted == [], "reaper disabled → no Secret deletes at all")

print("# 9. the grace period can never be shorter than two gc ticks")
mod = load(TOKEN_SECRET_GRACE_SECONDS="0", INTERVAL_SECONDS="30")
check(mod.TOKEN_GRACE_S >= 60, f"grace floor is 2 × interval (got {mod.TOKEN_GRACE_S})")

if FAILS:
    print(f"{len(FAILS)} check(s) failed")
    sys.exit(1)
print("all runner-gc token-Secret checks passed")
