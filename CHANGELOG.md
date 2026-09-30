# Changelog

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
