# Woow k3s Omnigent

[![k3s](https://img.shields.io/badge/k3s-%E2%89%A51.29-orange)](https://k3s.io)
[![Helm](https://img.shields.io/badge/helm-v3-blue)](https://helm.sh)
[![Omnigent](https://img.shields.io/badge/omnigent-0.11.0-blueviolet)](https://github.com/omnigent-ai/omnigent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

Sibling of [`Woow_podman_omnigent_package`](https://github.com/WOOWTECH/Woow_podman_omnigent_package),
packaged as a Helm chart for rootless k3s. Ships **postgres + omnigent-server +
N runner replicas + cloudflared sidecar**, with a post-install Job that
auto-claims the first admin so `helm install` is zero-manual-step.

## What you get

| | |
|---|---|
| **Public URL** | Whatever you configure via cloudflared (default: `https://omnigent.woowtech.io`) |
| **Server** | Upstream `ghcr.io/omnigent-ai/omnigent-server:latest` |
| **Runners** | `ghcr.io/woowtech/woow-omnigent-runner:main` — multi-arch manifest list (amd64 + arm64) built by the podman sibling's CI; one Deployment per host name (`pi1`, `pi4`, `pi5` by default) |
| **Database** | PostgreSQL 16-alpine as a StatefulSet, RWO Longhorn PVC |
| **Auth** | Built-in accounts; admin auto-claimed by post-install Job |
| **Ingress** | Cloudflared sidecar Deployment (2 replicas) using cloudflare-managed config |

## Why multiple runners

Each runner mounts its own RWO Longhorn PVC and registers with the server as a
separate host. In the web UI you get a host picker with all N entries — pick
one and its sessions/pi state stay on that runner.

Naming (`pi1`, `pi4`, `pi5`) is cosmetic and matches an operator convention on
`woow-k3s` where the pi-agent pods use the same numbering. State does **not**
share with the co-located pi-agent-N pods — those PVCs are RWO and can't be
co-mounted while the pi-agent pod is live.

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

# 2. Deploy
KUBECONTEXT=woow-k3s \
  CF_CREDS_JSON=/tmp/omnigent-tunnel-creds.json \
  scripts/apply.sh install

# 3. helm test — verifies /health, /v1/info admin claim, at least one online host
helm --kube-context woow-k3s test omnigent -n omnigent
```

Open `https://omnigent.woowtech.io/` (or whatever you configured), log in as
`woow` / `woowtech2026` (the defaults from `charts/omnigent/values.yaml` —
**change before deploying outside your trust boundary**).

## Install from GHCR (no git clone needed)

The chart is also published as an OCI artifact to
`ghcr.io/woowtech/charts/omnigent` on every push to `main` (as a pre-release
`X.Y.Z-main.<sha>` tag) and on every GitHub release (as the stable `X.Y.Z`
tag). Helm 3.8+ speaks OCI natively, so downstream consumers can skip the
`git clone` entirely:

```bash
# 1. Still need the cloudflared tunnel creds JSON (see the git-clone block
#    above for how to mint one). The released chart's default values expect
#    it — the shortcut path is to feed the file straight in with --set-file:
helm install omnigent oci://ghcr.io/woowtech/charts/omnigent \
  --version 0.1.0 \
  --create-namespace -n omnigent \
  --set-file cloudflared.credentials=creds.json

# 2. Seed still runs separately — the post-install Job auto-claims admin,
#    but you still need to helm test / helm upgrade after tuning any values.
helm test omnigent -n omnigent
```

Pin `--version` to a stable release (`X.Y.Z`) for production; `-main.<sha>`
tags exist for tracking `main` but aren't guaranteed to stick around.

## Chart layout

```
charts/omnigent/
  Chart.yaml
  values.yaml            # defaults (admin creds + images + storage sizes)
  values-woow.yaml       # in-repo overlay for the woow-k3s cluster
  templates/
    _helpers.tpl
    namespace.yaml
    secrets.yaml               # omnigent-admin + omnigent-postgres Secrets
    postgres-statefulset.yaml  # StatefulSet + headless Service + volumeClaimTemplate
    server-deployment.yaml     # Deployment + PVC + Service; optional pgbouncer sidecar
    runner-deployments.yaml    # N Deployments + N PVCs (per .Values.runner.hosts)
    setup-admin-job.yaml       # post-install/post-upgrade hook Job (auto-claim admin)
    host-gc-cronjob.yaml       # daily sweep for offline hosts (dry-run until upstream DELETE)
    host-gc-rbac.yaml          # ServiceAccount for the CronJob (no kube RBAC needed)
    cloudflared-deployment.yaml
    cloudflared-secret.yaml    # optional in-chart Secret rendered from values (OCI install path)
    tests/smoke.yaml           # helm test hook Pod
scripts/
  apply.sh                     # render / install / upgrade
  uninstall.sh                 # uninstall; --purge also deletes PVCs
  seed-pi-from.sh              # tar-pipe pi state from a live pi-agent-N pod into a runner PVC
tests/e2e/                     # Playwright suite (adapted from podman sibling)
docs/
  plans/2026-08-31-initial-package.md
  tests/                       # populated by e2e passes
.github/workflows/
  chart.yml                    # helm lint + kubeconform on push
  chart-release.yml            # helm package + push to ghcr.io/<owner>/charts (OCI)
```

## Design decisions vs. podman sibling

| Axis | Podman | k3s (this repo) |
|---|---|---|
| Unit | Quadlet | Helm chart |
| Runner count | 1 (single sidecar) | N (one per operator-named host) |
| Shared pi state | 1 external `pi-agent-data` volume | Each runner has its own fresh Longhorn PVC (RWO conflict with live pi-agent pods) |
| First-boot admin | `install.sh` curls `/auth/setup` | Helm post-install Job curls the same endpoint |
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

Pool mode defaults to **`session`** because omnigent's async SQLAlchemy
engine relies on prepared statements — `transaction` / `statement` modes
would break those. All knobs are values-tunable:

```yaml
pgbouncer:
  enabled: true                              # set false to bypass and connect direct
  image: docker.io/bitnami/pgbouncer:1.24.0
  poolMode: session                          # session | transaction | statement
  maxClientConn: 100
  defaultPoolSize: 25
  serverLifetime: 3600
  serverIdleTimeout: 600
  resources: {}
```

When `pgbouncer.enabled=false`, the server's `DATABASE_URL` reverts to the
Secret-baked `omnigent-postgres:5432` connection string; no sidecar is
rendered. Useful for A/B comparing pool vs. no-pool behaviour, or for
older deployments that predate the sidecar.

## Uninstall

```bash
KUBECONTEXT=woow-k3s scripts/uninstall.sh          # release only; keep PVCs
KUBECONTEXT=woow-k3s scripts/uninstall.sh --purge  # also drop PVCs + Secret + namespace
```

## Security notes

- **Default admin credentials are in `values.yaml`** — override with `--set admin.username=… --set admin.password=…` or a private `values-<env>.yaml` before deploying anywhere you don't trust.
- **Cloudflared tunnel creds live in a Secret named `omnigent-cloudflared-creds`** — `scripts/apply.sh` mints it from `CF_CREDS_JSON`. Never commit the JSON.
- **Postgres RWO PVC** — data loss on delete-pvc without a Longhorn snapshot. `uninstall.sh` without `--purge` preserves PVCs across reinstalls.
- **Runner-per-PVC design** means N × 20Gi Longhorn volumes. Tune `runner.storage.size` if pi state is small.

## License

MIT
