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
| `chart/` | `woow-paas/woow-paas-charts` | `charts/omnigent/` | `2d41c78f5a009666ea6625678c752c042036ae23` |

| Image | Pinned reference (chart default = platform pin) |
|---|---|
| server | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes:20260929.1400@sha256:ba384bba57cb1f80b28e3cbfab7c58d6ad94f5cd99c3773a86a1987ffe3bf902` |
| runner (managed sandbox) | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host:20260929.1400@sha256:558fce8ab8fe4b577787b523ebffccf970f56d2f99da7bfa9af9959a50ea04f9` |

Chart `0.1.0` / omnigent `0.16.0` — synced 2026-09-30 05:38 UTC.
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
