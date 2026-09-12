# Woow k3s Omnigent

[![k3s](https://img.shields.io/badge/k3s-%E2%89%A51.29-orange)](https://k3s.io)
[![Helm](https://img.shields.io/badge/helm-v3-blue)](https://helm.sh)
[![Omnigent](https://img.shields.io/badge/omnigent-0.11.0-blueviolet)](https://github.com/omnigent-ai/omnigent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

[`Woow_podman_omnigent_package`](https://github.com/WOOWTECH/Woow_podman_omnigent_package)
的姊妹版，改包成 Helm chart 部到 rootless k3s。內含 **postgres + omnigent-server +
N 個 runner Deployment + 一個 cloudflared Deployment**，由一個 Job 自動 claim 第一個
admin，所以 tunnel 憑證到位之後 `helm install` 不需要額外手動步驟。

這個 chart 就是 **woow-k3s** cluster（kubectl context `woow-k3s`）上 namespace
`omnigent` 的 Helm release `omnigent`。`values/woow-k3s/omnigent.yaml` 逐字記下那個
實例 — 用它 render 出來的物件跟 live 逐欄位相同，`scripts/check-drift.sh` 可以驗證。

## 提供什麼

| | |
|---|---|
| **對外 URL** | Cloudflared 設什麼就是什麼（預設 `https://omnigent.woowtech.io`） |
| **Server** | 上游 `ghcr.io/omnigent-ai/omnigent-server:latest` |
| **Runners** | `ghcr.io/woowtech/woow-omnigent-runner:main` — 多架構 manifest list（amd64 + arm64），podman 姊妹的 CI 產出；每個 host 名字（預設 `pi1`/`pi4`/`pi5`）一個 Deployment |
| **Database** | PostgreSQL 16-alpine StatefulSet，RWO Longhorn PVC |
| **Auth** | 上游 built-in accounts；admin 由 setup-admin Job 自動 claim。chart 內不含任何帳密，預設 `secrets.create=false` |
| **Ingress** | Cloudflared Deployment（2 replicas，是獨立 Deployment 不是 sidecar），cloudflare-managed config |

## 為什麼多個 runner

每個 runner 掛自己的 RWO Longhorn PVC，跟 server 註冊成獨立 host。Web UI 端會看到
一個 host picker 有 N 個項目 — 選哪個 session 就跑在哪個 runner 上，pi state 各自
獨立。

命名（`pi1`/`pi4`/`pi5`）純粹是操作習慣，對應 `woow-k3s` cluster 上 pi-agent pod 的
編號。**狀態不共享** — pi-agent-N 的 PVC 是 RWO 且被 live pi-agent pod 佔用，omnigent
runner 無法同時 mount。

## 帳密

chart **不帶任何密碼**。由 `secrets.create` 決定兩種模式：

| `secrets.create` | 行為 |
|---|---|
| `false`（預設） | Secret `omnigent-admin` 與 `omnigent-postgres` 必須已經存在於 namespace。chart 只引用它們，所以 upgrade 不可能覆蓋掉 live 帳密。用 `examples/secrets.example.yaml` 建立。 |
| `true` | chart 從 `admin.username`、`admin.password`、`postgres.password` 渲染兩個 Secret。三者都有 `required()` 保護，沒有預設值，沒填就 render 失敗。 |

```bash
# 全新安裝，讓 chart 管 Secret
helm install omnigent charts/omnigent -n omnigent --create-namespace \
  --set secrets.create=true \
  --set admin.username="$ADMIN_USER" \
  --set admin.password="$ADMIN_PASS" \
  --set postgres.password="$PG_PASS"
```

`keepOnUninstall: true`（預設）會在 Namespace、每一顆 PVC 與 chart 建立的 Secret 上加
`helm.sh/resource-policy: keep`，所以 `helm uninstall` 不會毀掉資料或 admin 帳號。

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

# 2. 確認 admin + Postgres Secret 已存在（或安裝時加 --set secrets.create=true …）
#    cp examples/secrets.example.yaml /secure/path/ ，改好之後：
#    kubectl --context woow-k3s -n omnigent apply -f /secure/path/secrets.yaml

# 3. 部署。現在帶 `--wait` 是安全的：claim admin 的 Job 是普通資源不是
#    post-install hook，不會再跟 runner 的 initContainer 互鎖
#    （以前會 — 見 templates/setup-admin-job.yaml）。
KUBECONTEXT=woow-k3s \
  CF_CREDS_JSON=/tmp/omnigent-tunnel-creds.json \
  scripts/apply.sh install

# 4. helm test — 唯讀：/health、/v1/info 有 claim admin、/auth/login、/v1/hosts
helm --kube-context woow-k3s test omnigent -n omnigent
```

開 `https://omnigent.woowtech.io/`（或你設的 URL），用 Secret `omnigent-admin`
裡的帳密登入。chart **不再內建任何預設帳密**：要嘛 Secret 已經存在（參考
`examples/secrets.example.yaml`），要嘛全新安裝時自己帶
`--set secrets.create=true --set admin.username=… --set admin.password=…`。

## 從 GHCR 安裝（不需 git clone）

Chart 也會以 OCI artifact 型式推到 `ghcr.io/woowtech/charts/omnigent`：
每次 push 到 `main` 會產一版 pre-release `X.Y.Z-main.<sha>`，每次 GitHub
release 會產一版穩定 `X.Y.Z`。Helm 3.8+ 原生支援 OCI，下游使用者可以完全
略過 `git clone`：

```bash
# 先看實際推上去有哪些版本。目前還沒有穩定的 X.Y.Z tag，所以直接
# `helm show chart` 會報 "Could not locate a version matching provided version
# string" — pre-release 版號要加 --devel 或明確 --version。
helm show chart oci://ghcr.io/woowtech/charts/omnigent --devel

# 1. 還是需要 cloudflared tunnel credentials JSON（怎麼建見上面 git-clone 段），
#    用 --set-file 直接把檔案吃進去：
helm install omnigent oci://ghcr.io/woowtech/charts/omnigent \
  --version 0.1.0-main.<sha> \
  --create-namespace -n omnigent \
  --set-file cloudflared.credentials=creds.json \
  --set secrets.create=true \
  --set admin.username="$ADMIN_USER" --set admin.password="$ADMIN_PASS" \
  --set postgres.password="$PG_PASS"

helm test omnigent -n omnigent
```

`--devel` 是用 **semver** 挑最新的 pre-release，而 `-main.<sha>` 是字典序排序，
所以「最新」不一定是最新的 commit — 請永遠自己指定 `--version`。有正式 release
之後就鎖穩定版（`X.Y.Z`）。

## 目錄結構

```
charts/omnigent/
  Chart.yaml
  .helmignore
  values.yaml            # 預設值 — images、大小、tuning。不含任何帳密。
  templates/
    _helpers.tpl
    NOTES.txt
    namespace.yaml             # 只在 namespace.create 且名稱 != release ns 時渲染
    secrets.yaml               # omnigent-admin + omnigent-postgres，只在 secrets.create 時渲染
    postgres-statefulset.yaml  # StatefulSet + Service + volumeClaimTemplate
    server-deployment.yaml     # Deployment + PVC + Service；可選 pgbouncer sidecar
    runner-deployments.yaml    # 每個 host 一顆 PVC，enabled 的 host 才有 Deployment
    setup-admin-job.yaml       # 普通 Job（自動 claim admin）— 刻意不用 hook
    host-gc-cronjob.yaml       # 每日 sweep 離線 host（其實收不掉東西：見 values.yaml）
    host-gc-rbac.yaml          # CronJob 的 ServiceAccount（無需 kube RBAC）
    cloudflared-deployment.yaml
    cloudflared-secret.yaml    # 可選 in-chart Secret（走 values 渲染，OCI install 用）
    tests/smoke.yaml           # helm test Pod，唯讀
values/woow-k3s/omnigent.yaml  # live woow-k3s 實例的 values，不含 secret
examples/secrets.example.yaml  # Secret 形狀，全是佔位值
scripts/
  apply.sh                     # render / install / upgrade
  uninstall.sh                 # uninstall；--purge 連 PVC 一起刪
  check-drift.sh               # render vs release vs live 物件比對
  normalize.py                 # render/live 逐欄位比對（唯讀）
  seed-pi-from.sh              # 從 live pi-agent-N pod tar-pipe pi state 到 runner PVC
tests/e2e/                     # Playwright suite（從 podman 姊妹 port 過來）
docs/
  plans/2026-08-31-initial-package.md
  tests/                       # e2e pass 產出放這
.github/workflows/
  chart.yml                    # lint、render 每種 values 組合、kubeconform、secret 檢查
  chart-release.yml            # helm package + push 到 ghcr.io/<owner>/charts (OCI)
```

## 跟 podman 姊妹的設計差異

| 軸 | Podman | k3s（本 repo） |
|---|---|---|
| 單位 | Quadlet | Helm chart |
| Runner 數 | 1（單 sidecar） | N（每個 operator 命名的 host 一個） |
| pi state 共享 | 1 個外部 `pi-agent-data` volume | 每 runner 一顆全新 Longhorn PVC（RWO 不能跟 live pi-agent pod 共 mount） |
| First-boot admin | `install.sh` curl `/auth/setup` | 一個普通 Job curl 同一個 endpoint（用 *hook* 會在 `--wait` 下跟 runner 的 initContainer 互鎖） |
| Runner login race | `runner-loop` 等 `/health` 才 login | 一樣，加 chart 端 `initContainer` 等 `needs_setup=false` — 否則 runner-loop 的 `sleep infinity` on login failure 會卡到手動重啟 |
| 對外 URL | Tailscale serve `--https=9444` | Cloudflared sidecar + cloudflare-managed config |
| Health probe | podman `HealthCmd` 打 `/health`（絕不 `/healthz` — SPA catch-all） | k8s `readinessProbe` + `livenessProbe` 打 `/health` |
| Image tag | `localhost/woow-omnigent-runner:latest`（本地 build） | `ghcr.io/woowtech/woow-omnigent-runner:main` 多架構 manifest（amd64 + arm64），podman 姊妹 CI 推的；本 repo 不 build image |

## Postgres 連線池

`omnigent-server` pod 內含一個 **pgbouncer sidecar**（`bitnami/pgbouncer`，
port 6432，pod 內限定、不開 Service），夾在 FastAPI server 跟
`omnigent-postgres` StatefulSet 中間。沒這一層時，Postgres 重啟後 server
的 asyncpg pool 會抱著壞掉的 socket，kubelet 得等 liveness 失敗到能殺掉並
重建 server pod — 2026-08-31 Resilience Test 3 實測 ~125s。加上 pool
front-end 後 Postgres flap 對 server 透明，目標復原時間 <30s，server pod
也不用重啟。

**大小設定跟「有沒有 pool」一樣關鍵。** server 的 SQLAlchemy engine 寫死
`pool_size=200, max_overflow=20`，所以舊的 `defaultPoolSize: 25` 在 session 模式下
會讓 pool 永久滿載：`query_wait_timeout` 120s → API 500 → `/health` 超過 probe
timeout（預設只有 1 秒！）→ liveness 每 ~30 分鐘 SIGKILL 一次 server container。
現在整條鏈對齊了，而且每個 probe 都明確設 `timeoutSeconds`：

```yaml
pgbouncer:
  enabled: true                              # 設 false 就跳過 pool 直連
  image: docker.io/bitnamilegacy/pgbouncer:1.24.1-debian-12-r10
  poolMode: session                          # session | transaction | statement
  maxClientConn: 1000
  defaultPoolSize: 200
  minPoolSize: 10
  reservePoolSize: 50
  reservePoolTimeout: 3
  queryWaitTimeout: 120
  maxDbConnections: 400                      # 要低於 postgres.tuning.maxConnections
  serverLifetime: 3600
  serverIdleTimeout: 600
```

Pool mode 仍然是 **`session`**。原本寫在這裡的理由（「靠 asyncpg 的 prepared
statement」）兩件事都錯了 — driver 是 psycopg3，而 pgbouncer 1.24 在 transaction
模式下本來就處理得了 protocol-level prepared statement。稽核過的結論是
`transaction` 對這個 app 是安全的；`session` 只是在不再飽和之後刻意保留的預設。

`pgbouncer.enabled=false` 時 server 的 `DATABASE_URL` 會 fallback 回
Secret 裡的 `omnigent-postgres:5432` 直連字串，sidecar 不 render。方便
A/B 比較有 pool / 沒 pool，或給更早期沒這個 sidecar 的部署用。

## 移除

```bash
KUBECONTEXT=woow-k3s scripts/uninstall.sh          # 只砍 release
KUBECONTEXT=woow-k3s scripts/uninstall.sh --purge  # 連 PVC + Secret + ns 都砍
```

不加 `--purge` 不會掉任何東西：`keepOnUninstall: true` 會在 Namespace、**每一顆**
PVC（包含 server 與 runner 的 — 這個 chart 舊版會把它們刪掉）以及 chart 建立的
Secret 上加 `helm.sh/resource-policy: keep`。Postgres 那顆是 StatefulSet 的
`volumeClaimTemplate`，本來就不屬於 Helm。

有一個無害的殘留：`helm test` 的 pod `omnigent-smoke` 用
`hook-delete-policy: before-hook-creation`（失敗時 log 才留得住），所以
`helm uninstall` 不會把它刪掉，namespace 裡會留一顆 `Completed` 的 pod。想清乾淨就
`kubectl -n <ns> delete pod omnigent-smoke`。

## 接管 / 升級 live release

live release 已經漂移：2026-09-06 與 2026-09-08 用 `kubectl patch` /
`kubectl set env` 改過設定但沒寫回 repo，三個 runner Deployment 也在 Helm 之外被刪掉。
`values/woow-k3s/omnigent.yaml` 現在把這些全部記錄下來，所以：

```bash
CONTEXT=woow-k3s scripts/check-drift.sh   # 唯讀；比對 render 與 live
```

升級前第 2 項檢查（「repo render vs live objects」）必須每個物件都逐欄位相符 —
那就是「升級不會重啟任何 pod」的保證。它是**雙向**比對：chart 宣告的欄位要跟 live
一致，而且**只存在於 live 的欄位**必須落在 `scripts/normalize.py` 的
`SERVER_DEFAULTS` 白名單內，否則就是失敗 — 因為「只有 live 有」正是 out-of-band
`kubectl patch` 留下的形狀。第 1 項是跟*已儲存的* release manifest 比，在第一次
upgrade 落地之前本來就會有差異。

**不要跑 `helm get values omnigent`。** revision 10 當初是用還帶著 admin 與 Postgres
密碼的 values 檔安裝的，這個指令會把兩組密碼以明文印在終端機與 shell history 裡。要取
參考基準請用 `helm get manifest` 或 `kubectl get -o yaml`，兩者都不會吐出帳密。（輪替
這兩組密碼列在 PR 的 follow-up；在那之前，對這個 release 執行 `helm get values` 等同於
把帳密倒出來。）

### 第一次 upgrade 會刪掉兩顆 Secret — 而且現在會被擋下來

revision 10 的 stored manifest 裡有 `Secret/omnigent-admin` 與
`Secret/omnigent-postgres`（當初是用 `secrets.create=true` 安裝的）。這個 chart 預設
`secrets.create=false`、兩顆都不渲染，所以直接 `helm upgrade` 會**把兩顆都刪掉**，而
Helm 還是回報 `STATUS: deployed` — 連帶把 server、runner、host-gc CronJob 與
`helm test` 都要讀的 admin 帳密和 Postgres 密碼／`DATABASE_URL` 一起帶走。

這件事不靠人記得。`scripts/apply.sh upgrade` 會先跑
`scripts/preflight-retain.sh` 並直接拒絕執行；`check-drift.sh` 也會唯讀地報同一件事。
沒有 skip 參數。要嘛自己下註記：

```bash
kubectl --context woow-k3s -n omnigent annotate secret omnigent-admin omnigent-postgres \
  helm.sh/resource-policy=keep
```

要嘛讓 preflight 幫你下（同一個註記，不會重啟任何東西）：

```bash
CONTEXT=woow-k3s scripts/preflight-retain.sh --fix              # 單獨執行
RETAIN_FIX=1 KUBECONTEXT=woow-k3s scripts/apply.sh upgrade      # 下註記、複查、再升級
```

preflight 也會列出 chart 不再渲染的三個 runner Deployment。它們早就在 Helm 之外被刪掉、
叢集上已經不存在，所以 upgrade 只是把它們從 manifest 移除 — 存著 pi-agent state 的 PVC
不受影響（`runner.hosts[].enabled: false`）。

## 安全性

- **chart 內不含任何帳密。** 預設 `secrets.create=false`；設 `true` 時 `admin.username` / `admin.password` / `postgres.password` 都有 `required()`。2026-09-12 之前的版本把 production 實際在用的 admin 與 Postgres 密碼 commit 進這個公開 repo — 現在檔案裡已經移除，但公開過的東西必須視為已洩漏並輪替
- **Cloudflared tunnel creds 存在名為 `omnigent-cloudflared-creds` 的 Secret** — `scripts/apply.sh` 從 `CF_CREDS_JSON` 自動建。JSON 絕不 commit
- **pgbouncer 用 `AUTH_TYPE=trust`** 而且宣告了 `containerPort: 6432`，image 又綁在 `0.0.0.0`。namespace 沒有任何 NetworkPolicy，所以叢集內任何能連到 server pod IP 的 pod 都能免密碼拿到 `omnigent` 的資料庫連線。要收掉得加 NetworkPolicy（這個 chart 還沒有）
- **所有 Pod 都沒有 `securityContext`** — 沒有 `runAsNonRoot`、`readOnlyRootFilesystem`，也沒有 drop capabilities
- **浮動 image tag。** `omnigent-server:latest` 與 `woow-omnigent-runner:main` 配 `imagePullPolicy: Always`，chart 版號又一直停在 `0.1.0`，光看 release 記錄無法重現一次部署
- **Postgres RWO PVC** — 沒 Longhorn snapshot 就 delete-pvc 會掉資料
- **Runner-per-PVC 設計** = N × 20Gi Longhorn volume。pi state 小可調 `runner.storage.size`，或用 `enabled: false` 讓某個 host 停跑但保留 volume

## 授權

MIT
