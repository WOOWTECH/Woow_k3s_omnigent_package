# Mirror provenance

This repository is a **read-only mirror** of the Omnigent cloud service that
runs on the WOOW PaaS platform. The source of truth is the internal Gitea
(`git-prod.woowtech.io`). Changes land there first, go through that repo's
review and prod approval gates, and are then synced here with
[`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh).

**Do not edit `chart/` here** — the next sync overwrites it. Open the change
against the Gitea repository instead.

## Current sync

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/omnigent/` | `50df613d30ff88ab1d82b217282e8dd71a908d37` |

| Image | Pinned reference (chart default = platform pin) |
|---|---|
| server | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes:20261111.0647@sha256:c6b6cab6478f06f6a36e3731cbd619d8d1bea8ece201da6e97c9dea97c38d72e` |
| runner (managed sandbox) | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host:20261111.0647@sha256:701101d009847e7dfb2c607314d42a38d171c9c44732c0e2a624177e02ce23bb` |

Chart `0.1.19` / omnigent `0.21.0` — synced 2026-11-14 13:36 UTC.
<!-- END GENERATED -->

## Where each piece comes from

| Piece | Source | Published as |
|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` `charts/omnigent/` | `oci://jcr-prod.woowtech.io/woow-paas-docker-local/omnigent` (private) |
| server image | upstream `ghcr.io/omnigent-ai/omnigent-server-kubernetes`, copied byte-for-byte (digest preserved) by `woow-paas/paas-odoo-ci` `mirror-image.yml` | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes` (private) |
| runner image | upstream `ghcr.io/omnigent-ai/omnigent-host`, copied the same way | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host` (private) |

There is no WOOW-built omnigent image: both images are the upstream release
with the same `sha256` digest as on ghcr.io.

## How the PaaS platform uses it

- The platform (`odoo-addons/woow_paas_platform`, template `omnigent`) pins the
  chart version and both images by `tag@sha256`; the chart defaults carry the
  same pins.
- Each tenant instance gets its own namespace-scoped release, one PVC (SQLite
  database, artifacts, cookie secret) and a Cloudflare-tunnel subdomain. The
  platform injects that public URL as `server.baseUrl`.
- **Login is omnigent's own accounts login** — there is no auth-proxy. The
  first admin (`admin`) is created at first boot from the password the platform
  shows once; the tenant changes it inside omnigent afterwards (the platform
  cannot reset it).
- **Cloud runners** use upstream's Kubernetes managed sandbox: each session gets
  an on-demand Job in the tenant namespace with a one-time launch token.
- **Your own machines** (including a PaaS pi-agent in the same workspace) join
  with omnigent's standard flow — `omnigent login <server-url>` then
  `omnigent host` on that machine. See the README.

## Resyncing

```bash
scripts/sync-from-gitea.sh              # woow-paas-charts at main
scripts/sync-from-gitea.sh <charts-ref>
```

Needs read access to the Gitea repository.

## History

The previous single-instance k3s package (omnigent 0.14.0 with PostgreSQL,
pgbouncer, cloudflared and N runner Deployments — the `omnigent` namespace
behind `omnigent.woowtech.io`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
and the `legacy-v0.2.0` tag. On 2026-09-30 this repository became the mirror of
the PaaS cloud service (omnigent 0.16.0).
