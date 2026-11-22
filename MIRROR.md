# Mirror provenance

This repository is a **read-only mirror** of the Omnigent cloud service that
runs on the WOOW PaaS platform. The source of truth is the internal Gitea
(`git-prod.woowtech.io`). Sync the exact canonical chart commit with
[`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh). Source review,
artifact publication and deployment approval remain separate gates.

**Do not edit `chart/` here** — the next sync overwrites it. Open the change
against the Gitea repository instead.

## Current sync

**Published chart `0.1.20`:** the canonical chart publication and approved
server mirror have been verified. The generated record below identifies the
exact canonical chart commit and image pins. Artifact publication does not
establish a production deployment. The managed host keeps its existing pin.

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/omnigent/` | `d5396c152ef1f415a4726294045bb755f2d5ef47` |

| Image | Pinned reference (chart default = platform pin) |
|---|---|
| server | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes:20261121.1104@sha256:ca7d431c241388f7ed7ae4db6b7583bd3952f303a68a53467985d5a1f33539e5` |
| runner (managed sandbox) | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host:20261111.0647@sha256:701101d009847e7dfb2c607314d42a38d171c9c44732c0e2a624177e02ce23bb` |

Chart `0.1.20` / omnigent `0.21.0` — synced 2026-11-22 01:45 UTC.
<!-- END GENERATED -->

## Where each piece comes from

| Piece | Source | Registry destination |
|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` `charts/omnigent/` | `oci://jcr-prod.woowtech.io/woow-paas-docker-local/omnigent` (private) |
| server image | `WOOWTECH/omnigent` build based on upstream `ghcr.io/omnigent-ai/omnigent-server-kubernetes`; approved candidate copied by `woow-paas/paas-odoo-ci` `mirror-image.yml` | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes` (private) |
| runner image | existing WOOW overlay based on upstream `ghcr.io/omnigent-ai/omnigent-host`; retained independently of the native MCP server wheel | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host` (private) |

These are WOOW builds of upstream Omnigent. Digest preservation applies when
copying the approved candidate into the registry mirror; it does not mean the
WOOW candidate has the same digest as its upstream base.

## Native MCP provenance

Chart `0.1.20` was published from canonical merge commit
`d5396c152ef1f415a4726294045bb755f2d5ef47`.
Its OCI digest is `sha256:8f0eba407664e6fe90bb1dc475169c8449a85bee414139d3b52860b87a398cd3`.
Publication CI run `47399` passed. The Gitea Helm and OCI chart archives were
verified byte-for-byte; their TGZ SHA-256 is
`5547b9230f7a81e0265d0d712ca2ae20fda311d361fa78bce0ff1019ee5f1ff9`.
The approved server mirror was verified by mirror CI run `47183`; its tag
`20261121.1104` preserves the producer image digest recorded above.
The producer source is `459340b0d9516fd3ecb4c35a95eb6e17cc3a5340`
(CI run `44896274348-1`). Chart and image publication were independently
verified before this mirror's release promotion.

The server build uses the shared portable WOOW wheel (`mcp.1`, upstream
package version `0.21.0`). The Kubernetes server image installs that wheel on
the corresponding upstream base. Keep the producer's `candidate-image.json`
and the image's `/opt/woow-artifact/WOOW_BUILD_RECEIPT.json` plus
`WOOW_CONTENT_MANIFEST.json` as the provenance chain. They identify the WOOW
source commit, wheel/UI hashes and image digests; the package version alone
does not identify the native MCP build.

The managed host and the `omnigent==0.21.0` CLI installation retain their
existing pins. Installing the server wheel does not authorize replacing the
host image.

There are two separate source identities:

- **Chart commit:** the reviewed commit in `woow-paas/woow-paas-charts` used
  by the sync script and recorded in the generated block.
- **Server source commit:** the `WOOWTECH/omnigent` commit in the producer
  receipt, carried with the wheel and candidate image.

For subsequent releases, verify human mirror approval, the mirror receipt
and canonical chart publication before release/main promotion. Record the
reviewed chart commit separately from the server source and compare the
published image and chart digests with their receipts. A candidate tag,
source-tree hash or proposed version is not evidence of publication.

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

Use the exact published canonical chart commit recorded above in both mirrors:

```bash
scripts/sync-from-gitea.sh d5396c152ef1f415a4726294045bb755f2d5ef47
```

Needs read access to the Gitea repository. The script also accepts branch/tag
refs and defaults to `main`; draft and release syncs use the reviewed exact commit.
It copies `chart/` and updates only the generated block above; it does not
build images, approve a mirror, or publish a chart.

Compare the generated commit and pins with the verified mirror and chart
receipts, run the mirrored chart's scoped CI checks, and keep both mirrors
aligned. Update the README version and provenance to match the verified
publication status.

Before release/main promotion, confirm that the chart defaults and platform
template seed agree on the chart version, server image digest and retained
host pin. Syncing or publishing artifacts does not authorize a production
deployment.

## History

The previous single-instance k3s package (omnigent 0.14.0 with PostgreSQL,
pgbouncer, cloudflared and N runner Deployments — the `omnigent` namespace
behind `omnigent.woowtech.io`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
and the `legacy-v0.2.0` tag. On 2026-09-30 this repository became the mirror of
the PaaS cloud service (omnigent 0.16.0).
