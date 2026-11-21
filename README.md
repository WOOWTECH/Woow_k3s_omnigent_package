# Woow Omnigent (WOOW PaaS cloud service)

**English** · [繁體中文](README_zh-TW.md)

A **read-only mirror** of the **Omnigent** cloud service on the WOOW PaaS
platform. The source of truth is the internal Gitea
(`woow-paas/woow-paas-charts`, `charts/omnigent/`); see
[MIRROR.md](MIRROR.md) for provenance and pinned versions. **Do not edit
`chart/` here** — the next sync overwrites it.

> The previous single-instance k3s package (omnigent 0.14.0 + PostgreSQL +
> cloudflared) is preserved on the
> [`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
> and the `legacy-v0.2.0` tag.

## What you get

| | |
|---|---|
| **Version** | omnigent **0.21.0** (draft chart `0.1.20`, not published) |
| **Provisioning** | Pick "Omnigent" in the PaaS marketplace — one instance per tenant |
| **URL** | Platform-assigned `https://paas-cs-<workspace>-<id>.woowtech.io` |
| **Login** | **omnigent's own accounts login** (no extra basic-auth prompt). User `admin`; the initial password is shown once at provisioning — change it inside omnigent, the platform cannot reset it later |
| **Data** | One PVC: SQLite database, uploaded artifacts, cookie secret |
| **Cloud runners** | Each session gets an isolated on-demand runner (omnigent-host, non-root) in the same namespace; idle runners drain |
| **Your own machines** | Any machine — including a PaaS pi-agent in the same workspace — joins with omnigent's standard flow (below) |
| **Size / price** | 4 vCPU / 8 GB RAM / 10 GB disk, 4,500 pts/month (7-day trial) |

## Architecture

- `chart/` renders a single server Deployment (:8000); its Service is the
  platform tunnel's entrance.
- The `admin` account is created at first boot from the platform-supplied
  initial password (`OMNIGENT_ACCOUNTS_INIT_ADMIN_*`), so there is no
  unauthenticated `POST /auth/setup` window on the public URL.
- Cloud runners use upstream's Kubernetes managed sandbox. The server's
  ServiceAccount is limited to jobs / pods / pods/log / secrets (create, delete
  only) / events in its own namespace — no `pods/exec`, no Secret reads.
- Public sharing is off by default; refresh grants last up to 365 days so
  connected machines keep renewing.

## Native MCP upgrade — draft

The checked-in `chart/` is the **unpublished 0.1.20 proposal**, synced from
reviewed canonical commit `184f409f182b95eb0629cb9ca0d7d84c66cac8b3`.
Its planned JCR server tag is `20261121.1104`, paired with the real producer
digest recorded in [MIRROR.md](MIRROR.md). The proposed JCR image and chart
remain **not published**, pending human mirror approval, a verified mirror
receipt and canonical chart publication.

The target server image installs the shared WOOW portable wheel, build
`mcp.1`, based on Omnigent `0.21.0`. Its receipt identifies the source commit,
wheel/UI hashes and image digests. The managed host keeps its existing
upstream-based `0.21.0` image pin; the CLI installation below remains
`omnigent==0.21.0`.

After the approved upgrade:

- Administrators manage profiles in **Settings → Admin → Omnigent MCP**.
  Creating a profile verifies the linked account's password; the server stores
  a revocable token hash. MCP operations follow that account's permissions.
- Clients use the API's canonical `connection_url`. Treat it as a bearer
  credential and keep it out of logs.
- `mcp.publicBaseUrl` supplies the complete external HTTPS base, including any
  deployment prefix, through `OMNIGENT_MCP_PUBLIC_BASE_URL`. An explicit value
  is preserved independently of `server.baseUrl`; no UI prefix is appended.
- Native MCP uses the existing server Service on port 8000.

**Draft preparation:** this exact canonical feature commit has been synced.
A reviewable Draft PR may be prepared before JCR approval or chart publication.
Keep the proposed JCR tag marked **not published** and paired with the real
producer digest from the canonical proposal.

**Release/main promotion:** wait for human JCR mirror approval, the verified
mirror receipt and the published canonical chart. Chart defaults and the
platform seed must agree on the server pin and retained host pin.
See [MIRROR.md](MIRROR.md#resyncing) for the provenance checks.

## Connecting your own machine

omnigent's standard flow, like two machines on the same LAN — the platform is
not involved:

```bash
omnigent login <omnigent URL>   # accounts mode: prompts for username + password
omnigent host                   # stays connected; the machine shows up in omnigent's Host menu
```

### A PaaS pi-agent in the same workspace

The pi-agent can use the **in-cluster address** (no public hop):
`http://<omnigent release>-omnigent.<namespace>.svc.cluster.local:8000`.

1. Install the omnigent CLI on the pi-agent (needs Python 3.12; uv keeps it on
   the persistent disk):
   ```bash
   export HOME=/data/pi-agent/home PATH=/data/pi-agent/home/.local/bin:$PATH
   curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=$HOME/.local/bin INSTALLER_NO_MODIFY_PATH=1 sh
   uv tool install --python 3.12 "omnigent==0.21.0"
   ```
2. Log in and connect:
   ```bash
   omnigent login http://<release>-omnigent.<namespace>.svc.cluster.local:8000
   PI_CODING_AGENT_DIR=/data/pi-agent omnigent host
   ```
3. **Let omnigent's Pi reuse the model configured in pi-web.** omnigent's Pi
   only trusts omnigent-managed providers by default. Adding "Pi original auth"
   to the pi-agent's `~/.omnigent/config.yaml` makes Pi use its own login (for
   example the ChatGPT account signed in to pi-web) — no separate API key:
   ```yaml
   providers:
     pi-original:
       kind: subscription
       cli: pi
       default: pi
   ```

Notes:
- Once a machine is registered to one omnigent account, reconnecting it as a
  different account is refused (409).
- `omnigent host` is started by hand for now; run it again after the pi-agent
  restarts.

## Syncing

```bash
scripts/sync-from-gitea.sh 184f409f182b95eb0629cb9ca0d7d84c66cac8b3
```

Draft sync may use the reviewed exact canonical feature commit before mirror
approval or chart publication. The generated provenance records the resolved
chart commit; the image receipt separately identifies the WOOW server source
and wheel. Keep the result in draft until the release gates above are satisfied.

## License

MIT
