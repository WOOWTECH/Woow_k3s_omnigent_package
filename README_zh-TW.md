# Woow k3s Omnigent

[![k3s](https://img.shields.io/badge/k3s-%E2%89%A51.29-orange)](https://k3s.io)
[![Helm](https://img.shields.io/badge/helm-v3-blue)](https://helm.sh)
[![Omnigent](https://img.shields.io/badge/omnigent-0.11.0-blueviolet)](https://github.com/omnigent-ai/omnigent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

[`Woow_podman_omnigent_package`](https://github.com/WOOWTECH/Woow_podman_omnigent_package)
的姊妹版，改包成 Helm chart 部到 rootless k3s。內含 **postgres + omnigent-server +
N 個 runner + cloudflared sidecar**，post-install Job 自動 claim 第一個 admin，
`helm install` 零手動步驟。

## 提供什麼

| | |
|---|---|
| **對外 URL** | Cloudflared 設什麼就是什麼（預設 `https://omnigent.woowtech.io`） |
| **Server** | 上游 `ghcr.io/omnigent-ai/omnigent-server:latest` |
| **Runners** | `ghcr.io/woowtech/woow-omnigent-runner-amd64:main`（podman 姊妹的 CI 產出）；每個 host 名字（預設 `pi1`/`pi4`/`pi5`）一個 Deployment |
| **Database** | PostgreSQL 16-alpine StatefulSet，RWO Longhorn PVC |
| **Auth** | 上游 built-in accounts；admin 由 post-install Job 自動 claim |
| **Ingress** | Cloudflared sidecar Deployment（2 replicas），cloudflare-managed config |

## 為什麼多個 runner

每個 runner 掛自己的 RWO Longhorn PVC，跟 server 註冊成獨立 host。Web UI 端會看到
一個 host picker 有 N 個項目 — 選哪個 session 就跑在哪個 runner 上，pi state 各自
獨立。

命名（`pi1`/`pi4`/`pi5`）純粹是操作習慣，對應 `woow-k3s` cluster 上 pi-agent pod 的
編號。**狀態不共享** — pi-agent-N 的 PVC 是 RWO 且被 live pi-agent pod 佔用，omnigent
runner 無法同時 mount。

## 安裝

需要 `helm`、`kubectl`、`jq`。假設有可用的 k3s cluster。

```bash
git clone https://github.com/WOOWTECH/Woow_k3s_omnigent_package.git
cd Woow_k3s_omnigent_package

# 1. 先建一個 cloudflared tunnel（走 CF dashboard 或 API），把 credentials
#    JSON 存起來讓 install script 讀得到。CF API 範例：
export CF_TOKEN='<CF API token，要 Zone:DNS:Edit + Account:Tunnel:Edit>'
export CF_ACCT='<CF account id>'
curl -sS -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
  -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCT}/cfd_tunnel" \
  --data '{"name":"omnigent-k3s","config_src":"cloudflare","tunnel_secret":"'"$(openssl rand -base64 32)"'"}'
# → 把回應中 {AccountTag, TunnelID, TunnelSecret} 存成 /tmp/omnigent-tunnel-creds.json
# 然後 push ingress config + 建 CNAME（詳細見 docs/plans/2026-08-31-initial-package.md）

# 2. 部署
KUBECONTEXT=woow-k3s \
  CF_CREDS_JSON=/tmp/omnigent-tunnel-creds.json \
  scripts/apply.sh install

# 3. helm test — 驗 /health、/v1/info 有 claim admin、至少 1 個 online host
helm --kube-context woow-k3s test omnigent -n omnigent
```

開 `https://omnigent.woowtech.io/`（或你設的 URL）登入 `woow` / `woowtech2026`
（`charts/omnigent/values.yaml` 的預設 — **信任邊界外部署前務必改**）。

## 目錄結構

```
charts/omnigent/
  Chart.yaml
  values.yaml            # 預設值（admin creds + images + storage 大小）
  values-woow.yaml       # 針對 woow-k3s cluster 的 in-repo overlay
  templates/
    _helpers.tpl
    namespace.yaml
    secrets.yaml               # omnigent-admin + omnigent-postgres Secrets
    postgres-statefulset.yaml  # StatefulSet + headless Service + volumeClaimTemplate
    server-deployment.yaml     # Deployment + PVC + Service
    runner-deployments.yaml    # 依 .Values.runner.hosts 產 N 個 Deployment + N 個 PVC
    setup-admin-job.yaml       # post-install/post-upgrade hook Job
    cloudflared-deployment.yaml
    tests/smoke.yaml           # helm test hook Pod
scripts/
  apply.sh                     # render / install / upgrade
  uninstall.sh                 # uninstall；--purge 連 PVC 一起刪
docs/
  plans/2026-08-31-initial-package.md
  tests/                       # e2e pass 產出放這
.github/workflows/
  chart.yml                    # push 時 helm lint + kubeconform
```

## 跟 podman 姊妹的設計差異

| 軸 | Podman | k3s（本 repo） |
|---|---|---|
| 單位 | Quadlet | Helm chart |
| Runner 數 | 1（單 sidecar） | N（每個 operator 命名的 host 一個） |
| pi state 共享 | 1 個外部 `pi-agent-data` volume | 每 runner 一顆全新 Longhorn PVC（RWO 不能跟 live pi-agent pod 共 mount） |
| First-boot admin | `install.sh` curl `/auth/setup` | Helm post-install Job curl 同一個 endpoint |
| Runner login race | `runner-loop` 等 `/health` 才 login | 一樣，加 chart 端 `initContainer` 等 `needs_setup=false` — 否則 runner-loop 的 `sleep infinity` on login failure 會卡到手動重啟 |
| 對外 URL | Tailscale serve `--https=9444` | Cloudflared sidecar + cloudflare-managed config |
| Health probe | podman `HealthCmd` 打 `/health`（絕不 `/healthz` — SPA catch-all） | k8s `readinessProbe` + `livenessProbe` 打 `/health` |
| Image tag | `localhost/woow-omnigent-runner:latest`（本地 build） | `ghcr.io/woowtech/woow-omnigent-runner-amd64:main`（podman 姊妹 CI 推的；本 repo 不 build image） |

## 移除

```bash
KUBECONTEXT=woow-k3s scripts/uninstall.sh          # 只砍 release，保留 PVC
KUBECONTEXT=woow-k3s scripts/uninstall.sh --purge  # 連 PVC + Secret + ns 都砍
```

## 安全性

- **預設 admin credentials 在 `values.yaml`** — 部署到不信任環境前用 `--set admin.username=… --set admin.password=…` 或私 `values-<env>.yaml` 覆蓋
- **Cloudflared tunnel creds 存在名為 `omnigent-cloudflared-creds` 的 Secret** — `scripts/apply.sh` 從 `CF_CREDS_JSON` 自動建。JSON 絕不 commit
- **Postgres RWO PVC** — 沒 Longhorn snapshot 就 delete-pvc 會掉資料。`uninstall.sh` 不加 `--purge` 保留 PVC 讓重裝續用
- **Runner-per-PVC 設計** = N × 20Gi Longhorn volume。pi state 小可調 `runner.storage.size`

## 授權

MIT
