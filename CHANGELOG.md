# Changelog

## 1.1.0 — 2026-11-14

Resync from `woow-paas/woow-paas-charts` `main` (`50df613d`): chart `0.1.0` →
`0.1.19`, omnigent `0.16.0` → `0.21.0`. The mirror had not been resynced since
2026-09-30; the Omnigent tenants on the platform already run chart `0.1.19`.
See [MIRROR.md](MIRROR.md) for the pinned images.

- Images: server (`omnigent-server-kubernetes`) and runner (`omnigent-host`) are
  now the WoowTech overlay builds of upstream v0.21.0, tag `20261111.0647`,
  pinned by digest in jcr-prod.
- Upgrade path 0.16.0 → 0.17.0 → 0.19.1 → 0.20.0 → 0.21.0. The Alembic
  migrations that come with these are one-way; `chart/Chart.yaml` lists the
  rollback steps per chart version.
- Network: egress is no longer allow-all (DNS, kube-apiserver, same-namespace
  traffic and internet 80/443). Runner Pods get their own NetworkPolicy and wait
  for it at start-up (`runner.egressGate`); server and LLM-proxy Pods carry
  `paas.woowtech.io/egress-profile=web`.
- LLM keys for managed sessions go through a per-release proxy
  (`llmProxy.*`), so runners never hold the real keys.
- Least privilege: the server ServiceAccount lost `pods:create`; the runner-gc
  sidecar reaps orphaned runner token Secrets and now has a 256Mi limit.
- Readiness also needs a successful write + fsync on `/data`, so a full volume
  no longer shows Ready.
- Public surface: anonymous `/docs`, `/redoc` and `/openapi.json` return 404
  unless `server.publicApiDocs` is set; HSTS is always on.
- New options: external database through `server.database.existingSecret`;
  `server.sessionOrchestration` (default off — upstream 0.21 turns it on, which
  lets agents start unlimited managed runner Jobs, so the chart keeps the 0.20
  behaviour unless a tenant opts in).
- Unchanged defaults: public sharing off (`server.publicSharing: false`) and
  refresh grants last up to 365 days (`server.grantMaxLifetimeDays: 365`).
- README: version line and the `omnigent==` install pin now say 0.21.0.

## 1.0.0 — 2026-09-30

This repository becomes a **read-only mirror of the WOOW PaaS Omnigent cloud
service** (`woow-paas/woow-paas-charts` `charts/omnigent/`, chart `0.1.0`,
omnigent `0.16.0`). See [MIRROR.md](MIRROR.md).

- `chart/`: per-tenant chart — single server, SQLite on one PVC, omnigent's own
  accounts login (no auth-proxy), admin created at first boot, upstream
  Kubernetes managed-sandbox runners, release-prefixed names, non-root,
  default-deny NetworkPolicy.
- Images are the upstream ghcr.io releases copied byte-for-byte into jcr-prod
  (server `omnigent-server-kubernetes`, runner `omnigent-host`, both
  `20260929.1400`).
- `scripts/sync-from-gitea.sh` resyncs `chart/` and the generated block of
  MIRROR.md.
- Removed the single-instance package (PostgreSQL + pgbouncer, cloudflared,
  per-host runner Deployments, apply/drift scripts, e2e suite, GHCR chart
  release). It is preserved on `legacy/k3s-single-instance` and tag
  `legacy-v0.2.0`.
