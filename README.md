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
| **Version** | omnigent **0.16.0** (chart `0.1.0`) |
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
   uv tool install --python 3.12 "omnigent==0.16.0"
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
scripts/sync-from-gitea.sh              # woow-paas-charts at main
```

## License

MIT
