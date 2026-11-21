# Mirror provenance

This repository is a **read-only mirror** of the Omnigent cloud service that
runs on the WOOW PaaS platform. The source of truth is the internal Gitea
(`git-prod.woowtech.io`). Draft mirrors can sync a reviewed canonical feature
commit with [`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh) before
publication. Release/main promotion retains the source review and production
approval gates described below.

**Do not edit `chart/` here** — the next sync overwrites it. Open the change
against the Gitea repository instead.

## Current sync

**Draft / not published:** this is the reviewed chart `0.1.20` proposal.
The server reference below combines planned JCR tag `20261121.1104` with the
real producer digest; it does not establish JCR availability. Human mirror
approval, a verified mirror receipt and canonical chart publication remain
pending. The managed host keeps its existing pin.

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/omnigent/` | `184f409f182b95eb0629cb9ca0d7d84c66cac8b3` |

| Image | Pinned reference (chart default = platform pin) |
|---|---|
| server | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-server-kubernetes:20261121.1104@sha256:ca7d431c241388f7ed7ae4db6b7583bd3952f303a68a53467985d5a1f33539e5` |
| runner (managed sandbox) | `jcr-prod.woowtech.io/woow-paas-docker-local/omnigent-host:20261111.0647@sha256:701101d009847e7dfb2c607314d42a38d171c9c44732c0e2a624177e02ce23bb` |

Chart `0.1.20` / omnigent `0.21.0` — synced 2026-11-21 11:27 UTC.
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

## Native MCP provenance — draft

The generated record above is the current draft sync from reviewed canonical
feature commit `184f409f182b95eb0629cb9ca0d7d84c66cac8b3`. It advances the
chart from `0.1.19` to the unpublished `0.1.20` proposal and records the
planned JCR server tag `20261121.1104` with the actual producer digest.
The producer source is `459340b0d9516fd3ecb4c35a95eb6e17cc3a5340`
(CI run `44896274348-1`). This draft sync does not publish the image or chart.

The proposed server build uses the shared portable WOOW wheel (`mcp.1`, upstream
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

Draft sync and Draft PR preparation may proceed from a reviewed full canonical
feature commit before human JCR approval or chart publication. Copy the actual
proposal, including its real producer digest and planned JCR tag, and clearly
mark that registry reference and chart proposal as **not published**.

Release/main promotion must wait for human JCR mirror approval, the verified
mirror receipt and canonical chart publication. For release evidence, do not
substitute a candidate tag, source-tree hash, or proposed chart version for
the approved image digest or published chart.

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

For a reviewable native MCP draft, use the supplied reviewed full canonical
feature commit in both mirrors. This can happen before JCR mirror approval or
chart publication:

```bash
scripts/sync-from-gitea.sh 184f409f182b95eb0629cb9ca0d7d84c66cac8b3
```

Needs read access to the Gitea repository. The script also accepts branch/tag
refs and defaults to `main`; draft and release syncs use the reviewed exact commit.
It copies `chart/` and updates only the generated block above; it does not
build images, approve a mirror, or publish a chart.

After draft sync, update the README version/current-chart wording to describe
the actual proposal and retain its **draft / not published** status. Review
the generated commit and pins against the producer receipt, run the mirrored
chart's CI checks, and keep both mirrors aligned.

Before release/main promotion, verify the approved mirror receipt and published
chart, and confirm the chart defaults and platform template seed agree on the
chart version, server image digest and retained host pin. A completed draft
sync does not authorize publication or a production deployment.

## History

The previous single-instance k3s package (omnigent 0.14.0 with PostgreSQL,
pgbouncer, cloudflared and N runner Deployments — the `omnigent` namespace
behind `omnigent.woowtech.io`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
and the `legacy-v0.2.0` tag. On 2026-09-30 this repository became the mirror of
the PaaS cloud service (omnigent 0.16.0).
