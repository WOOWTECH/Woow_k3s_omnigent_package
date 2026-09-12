# Woow k3s Omnigent

[![k3s](https://img.shields.io/badge/k3s-%E2%89%A51.29-orange)](https://k3s.io)
[![Helm](https://img.shields.io/badge/helm-v3-blue)](https://helm.sh)
[![Omnigent](https://img.shields.io/badge/omnigent-0.11.0-blueviolet)](https://github.com/omnigent-ai/omnigent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

Sibling of [`Woow_podman_omnigent_package`](https://github.com/WOOWTECH/Woow_podman_omnigent_package),
packaged as a Helm chart for rootless k3s. Ships **postgres + omnigent-server +
N runner Deployments + a cloudflared Deployment**, with a Job that auto-claims
the first admin so `helm install` needs no manual step after the tunnel
credentials are in place.

This chart is what runs on the **woow-k3s** cluster (kubectl context
`woow-k3s`) as Helm release `omnigent` in namespace `omnigent`.
`values/woow-k3s/omnigent.yaml` records that instance exactly — rendering the
chart with it reproduces the live objects field for field, and
`scripts/check-drift.sh` proves it.

## What you get

| | |
|---|---|
| **Public URL** | Whatever you configure via cloudflared (default: `https://omnigent.woowtech.io`) |
| **Server** | Upstream `ghcr.io/omnigent-ai/omnigent-server:latest` |
| **Runners** | `ghcr.io/woowtech/woow-omnigent-runner:main` — multi-arch manifest list (amd64 + arm64) built by the podman sibling's CI; one Deployment per host name (`pi1`, `pi4`, `pi5` by default) |
| **Database** | PostgreSQL 16-alpine as a StatefulSet, RWO Longhorn PVC |
| **Auth** | Built-in accounts; admin auto-claimed by the setup-admin Job. No credentials ship in the chart — `secrets.create=false` by default |
| **Ingress** | Cloudflared Deployment (2 replicas, its own Deployment — not a sidecar) using cloudflare-managed config |

## Why multiple runners

Each runner mounts its own RWO Longhorn PVC and registers with the server as a
separate host. In the web UI you get a host picker with all N entries — pick
one and its sessions/pi state stay on that runner.

Naming (`pi1`, `pi4`, `pi5`) is cosmetic and matches an operator convention on
`woow-k3s` where the pi-agent pods use the same numbering. State does **not**
share with the co-located pi-agent-N pods — those PVCs are RWO and can't be
co-mounted while the pi-agent pod is live.

## Credentials

The chart carries **no** passwords. Two modes, both selected by
`secrets.create`:

| `secrets.create` | Behaviour |
|---|---|
| `false` (default) | The Secrets `omnigent-admin` and `omnigent-postgres` must already exist in the namespace. The chart only references them, so an upgrade can never overwrite live credentials. Create them from `examples/secrets.example.yaml`. |
| `true` | The chart renders both Secrets from `admin.username`, `admin.password` and `postgres.password`. All three are `required()` — there is no default, so a render fails until you supply real values. |

```bash
# fresh install, chart-managed Secrets
helm install omnigent charts/omnigent -n omnigent --create-namespace \
  --set secrets.create=true \
  --set admin.username="$ADMIN_USER" \
  --set admin.password="$ADMIN_PASS" \
  --set postgres.password="$PG_PASS"
```

With `keepOnUninstall: true` (the default) the Namespace, every PVC and the
chart-created Secrets carry `helm.sh/resource-policy: keep`, so
`helm uninstall` never destroys data or the admin account.

## Install

Requires `helm`, `kubectl`, `jq`. Assumes a working k3s cluster.

```bash
git clone https://github.com/WOOWTECH/Woow_k3s_omnigent_package.git
cd Woow_k3s_omnigent_package

# 1. Create a cloudflared tunnel via the CF dashboard or API, save the
#    credentials JSON somewhere the install script can read it.
#    Example (using the CF API):
export CF_TOKEN='<your CF API token with Zone:DNS:Edit + Account:Tunnel:Edit>'
export CF_ACCT='<your CF account id>'
curl -sS -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
  -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCT}/cfd_tunnel" \
  --data '{"name":"omnigent-k3s","config_src":"cloudflare","tunnel_secret":"'"$(openssl rand -base64 32)"'"}'
# → save {AccountTag, TunnelID, TunnelSecret} to /tmp/omnigent-tunnel-creds.json
# then push the ingress config + CNAME (see docs/plans/2026-08-31-initial-package.md).

# 2. Make sure the admin + Postgres Secrets exist (or add --set secrets.create=true …)
#    cp examples/secrets.example.yaml /secure/path/ ; edit ; then:
#    kubectl --context woow-k3s -n omnigent apply -f /secure/path/secrets.yaml

# 3. Deploy. `--wait` is safe: the admin-claim Job is an ordinary resource, not
#    a post-install hook, so it cannot deadlock against the runners' init
#    container (it used to — see templates/setup-admin-job.yaml).
KUBECONTEXT=woow-k3s \
  CF_CREDS_JSON=/tmp/omnigent-tunnel-creds.json \
  scripts/apply.sh install

# 4. helm test — read-only: /health, /v1/info admin claim, /auth/login, /v1/hosts
helm --kube-context woow-k3s test omnigent -n omnigent
```

Open `https://omnigent.woowtech.io/` (or whatever you configured) and log in
with the credentials in the `omnigent-admin` Secret. The chart ships **no**
default credentials: either the Secret already exists (see
`examples/secrets.example.yaml`) or you pass your own on a fresh install with
`--set secrets.create=true --set admin.username=… --set admin.password=…`.

## Install from GHCR (no git clone needed)

The chart is also published as an OCI artifact to
`ghcr.io/woowtech/charts/omnigent` on every push to `main` (as a pre-release
`X.Y.Z-main.<sha>` tag) and on every GitHub release (as the stable `X.Y.Z`
tag). Helm 3.8+ speaks OCI natively, so downstream consumers can skip the
`git clone` entirely:

```bash
# List what is actually published. There is no stable X.Y.Z tag yet, so a plain
# `helm show chart` fails with "Could not locate a version matching provided
# version string" — pre-release tags need --devel or an explicit --version.
helm show chart oci://ghcr.io/woowtech/charts/omnigent --devel

# 1. Still need the cloudflared tunnel creds JSON (see the git-clone block
#    above for how to mint one) — feed the file straight in with --set-file:
helm install omnigent oci://ghcr.io/woowtech/charts/omnigent \
  --version 0.1.0-main.<sha> \
  --create-namespace -n omnigent \
  --set-file cloudflared.credentials=creds.json \
  --set secrets.create=true \
  --set admin.username="$ADMIN_USER" --set admin.password="$ADMIN_PASS" \
  --set postgres.password="$PG_PASS"

helm test omnigent -n omnigent
```

`--devel` resolves the newest pre-release by **semver**, and `-main.<sha>` tags
sort lexically, so "newest" is not necessarily the newest commit — always pass
the `--version` you mean. Pin a stable release (`X.Y.Z`) once one is cut.

## Chart layout

```
charts/omnigent/
  Chart.yaml
  .helmignore
  values.yaml            # defaults — images, sizes, tuning. NO credentials.
  templates/
    _helpers.tpl
    NOTES.txt
    namespace.yaml             # only when namespace.create and name != release ns
    secrets.yaml               # omnigent-admin + omnigent-postgres, secrets.create only
    postgres-statefulset.yaml  # StatefulSet + Service + volumeClaimTemplate
    server-deployment.yaml     # Deployment + PVC + Service; optional pgbouncer sidecar
    runner-deployments.yaml    # one PVC per host, Deployment per enabled host
    setup-admin-job.yaml       # ordinary Job (auto-claim admin) — deliberately not a hook
    host-gc-cronjob.yaml       # daily sweep for offline hosts (cannot prune: see values.yaml)
    host-gc-rbac.yaml          # ServiceAccount for the CronJob (no kube RBAC needed)
    cloudflared-deployment.yaml
    cloudflared-secret.yaml    # optional in-chart Secret rendered from values (OCI install path)
    tests/smoke.yaml           # helm test Pod, read-only
values/woow-k3s/omnigent.yaml  # the LIVE woow-k3s instance, secret-free
examples/secrets.example.yaml  # Secret shapes, placeholders only
scripts/
  apply.sh                     # render / install / upgrade
  uninstall.sh                 # uninstall; --purge also deletes PVCs
  check-drift.sh               # render vs release vs live objects
  normalize.py                 # field-by-field render/live comparison (read-only)
  seed-pi-from.sh              # tar-pipe pi state from a live pi-agent-N pod into a runner PVC
tests/e2e/                     # Playwright suite (adapted from podman sibling)
docs/
  plans/2026-08-31-initial-package.md
  tests/                       # populated by e2e passes
.github/workflows/
  chart.yml                    # lint, template every combination, kubeconform, secret guards
  chart-release.yml            # helm package + push to ghcr.io/<owner>/charts (OCI)
```

## Design decisions vs. podman sibling

| Axis | Podman | k3s (this repo) |
|---|---|---|
| Unit | Quadlet | Helm chart |
| Runner count | 1 (single sidecar) | N (one per operator-named host) |
| Shared pi state | 1 external `pi-agent-data` volume | Each runner has its own fresh Longhorn PVC (RWO conflict with live pi-agent pods) |
| First-boot admin | `install.sh` curls `/auth/setup` | An ordinary Job curls the same endpoint (a *hook* deadlocked against the runners' init container under `--wait`) |
| Runner login race | `runner-loop` waits for `/health` before login | Same, plus a chart-side `initContainer` waits for `needs_setup=false` — otherwise the runner-loop's `sleep infinity` on login failure blocks until manual restart |
| Public URL | Tailscale serve `--https=9444` | Cloudflared sidecar with cloudflare-managed config |
| Health probe | podman `HealthCmd` on `/health` (never `/healthz` — SPA catch-all) | k8s `readinessProbe` + `livenessProbe` on `/health` |
| Image tag | Uses `localhost/woow-omnigent-runner:latest` (local build) | Uses `ghcr.io/woowtech/woow-omnigent-runner:main` multi-arch manifest (amd64 + arm64) — published by podman sibling's CI, no image build in this repo |

## Postgres connection pooling

The `omnigent-server` pod ships a **pgbouncer sidecar** (`bitnami/pgbouncer`,
port 6432, pod-local, no Service) that sits between the FastAPI server and the
`omnigent-postgres` StatefulSet. Without it, when Postgres restarts the
server's asyncpg pool held stale sockets and kubelet needed ~125s (measured
in Resilience Test 3 on 2026-08-31) to fail liveness enough times to
restart the server pod. With the pool front-end, Postgres flaps become
transparent — target recovery is <30s and the server pod stays up.

**Sizing matters as much as presence.** The server's SQLAlchemy engine
hardcodes `pool_size=200, max_overflow=20`, so the old `defaultPoolSize: 25`
left the pool permanently full in session mode: `query_wait_timeout` after
120s → API 500s → `/health` past its (1s default!) probe timeout → liveness
SIGKILL of the server container roughly every 30 minutes. The chain is now
aligned end to end, and every probe sets `timeoutSeconds` explicitly:

```yaml
pgbouncer:
  enabled: true                              # set false to bypass and connect direct
  image: docker.io/bitnamilegacy/pgbouncer:1.24.1-debian-12-r10
  poolMode: session                          # session | transaction | statement
  maxClientConn: 1000
  defaultPoolSize: 200
  minPoolSize: 10
  reservePoolSize: 50
  reservePoolTimeout: 3
  queryWaitTimeout: 120
  maxDbConnections: 400                      # stays below postgres.tuning.maxConnections
  serverLifetime: 3600
  serverIdleTimeout: 600
```

Pool mode stays **`session`**. The note that used to live here ("relies on
asyncpg prepared statements") was wrong on both counts — the driver is
psycopg3 and pgbouncer 1.24 handles protocol-level prepared statements in
transaction mode. `transaction` is audited-safe for this app; `session` is
simply the deliberate default now that it no longer saturates.

When `pgbouncer.enabled=false`, the server's `DATABASE_URL` reverts to the
Secret-baked `omnigent-postgres:5432` connection string; no sidecar is
rendered. Useful for A/B comparing pool vs. no-pool behaviour, or for
older deployments that predate the sidecar.

## Uninstall

```bash
KUBECONTEXT=woow-k3s scripts/uninstall.sh          # release only
KUBECONTEXT=woow-k3s scripts/uninstall.sh --purge  # also drop PVCs + Secret + namespace
```

Without `--purge` nothing is lost: `keepOnUninstall: true` puts
`helm.sh/resource-policy: keep` on the Namespace, **every** PVC (server and
runner PVCs included — earlier revisions of this chart deleted those) and the
chart-created Secrets. The Postgres volume is a StatefulSet
`volumeClaimTemplate`, which Helm never owned in the first place.

One cosmetic leftover: the `helm test` pod `omnigent-smoke` uses
`hook-delete-policy: before-hook-creation` (so its logs survive a failure and are
still readable afterwards), which means `helm uninstall` does not remove it. A
single `Completed` pod stays behind in the namespace; delete it with
`kubectl -n <ns> delete pod omnigent-smoke` if you want a clean listing.

## Taking over / upgrading the live release

The live release drifted: settings were applied with `kubectl patch` /
`kubectl set env` on 2026-09-06 and 2026-09-08 and were never written back, and
the three runner Deployments were deleted outside Helm.
`values/woow-k3s/omnigent.yaml` now records all of it, so:

```bash
CONTEXT=woow-k3s scripts/check-drift.sh   # read-only; compares render to live
```

Check 2 ("repo render vs live objects") must report every object matching field
for field before you run an upgrade — that is the guarantee that the upgrade
rolls no pods. It compares in **both** directions: a field the chart declares
must match live, *and* a field that exists only live must be a known
API-server default from `SERVER_DEFAULTS` in `scripts/normalize.py`. Anything
else fails, because a live-only field is exactly what an out-of-band
`kubectl patch` leaves behind. Check 1 compares against the *stored* release
manifest and is expected to differ until the first upgrade lands.

**Do not run `helm get values omnigent`.** Revision 10 was installed from a
values file that still carried the admin and Postgres passwords, so that command
prints both in clear text into your terminal and your shell history. Use
`helm get manifest` or `kubectl get -o yaml` to derive a reference; neither
exposes a credential. (Rotating those two passwords is a follow-up — until it
happens, treat `helm get values` on this release as a credential dump.)

### The first upgrade would delete two Secrets — and is blocked until you fix it

Revision 10's stored manifest contains `Secret/omnigent-admin` and
`Secret/omnigent-postgres` (it was installed with `secrets.create=true`). This
chart defaults to `secrets.create=false` and renders neither, so a plain
`helm upgrade` **deletes both** while reporting `STATUS: deployed` — taking the
admin credentials and the Postgres password/`DATABASE_URL` that the server, the
runners, the host-gc CronJob and `helm test` all read.

That is not left to memory. `scripts/apply.sh upgrade` runs
`scripts/preflight-retain.sh` first and refuses to continue; `check-drift.sh`
reports the same thing read-only. There is no skip flag. Either annotate the two
Secrets yourself:

```bash
kubectl --context woow-k3s -n omnigent annotate secret omnigent-admin omnigent-postgres \
  helm.sh/resource-policy=keep
```

or let the preflight do it, which is the same annotation and restarts nothing:

```bash
CONTEXT=woow-k3s scripts/preflight-retain.sh --fix       # standalone
RETAIN_FIX=1 KUBECONTEXT=woow-k3s scripts/apply.sh upgrade   # annotate, verify, upgrade
```

The preflight also lists the three runner Deployments the chart no longer
renders. They were deleted out of band and are already absent from the cluster,
so the upgrade simply drops them from the manifest — the PVCs holding their
pi-agent state are untouched (`runner.hosts[].enabled: false`).

## Security notes

- **No credentials in the chart.** `secrets.create=false` by default; with `true`, `admin.username` / `admin.password` / `postgres.password` are `required()`. Revisions of this repo before 2026-09-12 committed the admin and Postgres passwords that the production deployment was actually using — they are gone from the tree, but anything committed to a public repo must be treated as disclosed and rotated.
- **Cloudflared tunnel creds live in a Secret named `omnigent-cloudflared-creds`** — `scripts/apply.sh` mints it from `CF_CREDS_JSON`. Never commit the JSON.
- **pgbouncer runs with `AUTH_TYPE=trust`** and declares `containerPort: 6432`, and the image binds `0.0.0.0`. Any pod that can reach the server pod IP gets an unauthenticated `omnigent` database session, because the namespace has no NetworkPolicy. Restricting this needs a NetworkPolicy (not yet in this chart).
- **No pod sets a `securityContext`** — no `runAsNonRoot`, no `readOnlyRootFilesystem`, no dropped capabilities.
- **Floating image tags.** `omnigent-server:latest` and `woow-omnigent-runner:main` with `imagePullPolicy: Always`, and the chart version never moves off `0.1.0`, so a deployment is not reproducible from the release record alone.
- **Postgres RWO PVC** — data loss on delete-pvc without a Longhorn snapshot.
- **Runner-per-PVC design** means N × 20Gi Longhorn volumes. Tune `runner.storage.size` if pi state is small, or park a host with `enabled: false` to keep its volume without running it.

## License

MIT
