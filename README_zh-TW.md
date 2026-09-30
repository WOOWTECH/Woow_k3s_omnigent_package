# Woow Omnigent（WOOW PaaS 雲端服務）

[English](README.md) · **繁體中文**

WOOW PaaS 上 **Omnigent** 雲端服務的**唯讀鏡像**。真正的來源在內部 Gitea
（`woow-paas/woow-paas-charts` 的 `charts/omnigent/`），同步方式與版本對照見
[MIRROR.md](MIRROR.md)。**請勿在這裡修改 `chart/`**，下次同步會覆蓋。

> 先前的單一實體 k3s 套件（omnigent 0.14.0＋PostgreSQL＋cloudflared）保留在
> [`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) 分支與
> `legacy-v0.2.0` tag。

## 提供什麼

| | |
|---|---|
| **版本** | omnigent **0.16.0**（chart `0.1.0`） |
| **開通** | 在 PaaS 的應用市集選「Omnigent」，每個租戶一台 |
| **網址** | 平台自動配發的 `https://paas-cs-<工作區>-<代號>.woowtech.io` |
| **登入** | **omnigent 自己的帳號登入**（沒有額外的帳密視窗）。帳號 `admin`，初始密碼在開通時顯示一次；登入後請在 omnigent 內修改，平台之後無法代為重設 |
| **資料** | 一顆 PVC：SQLite 資料庫、上傳檔案、cookie secret |
| **雲端工作機** | 每開一個工作階段，自動在同一個 namespace 開一個隔離的 runner（omnigent-host，非 root），閒置後自動收回 |
| **自己的機器** | 任何機器（含同工作區的 PaaS pi-agent）都能用 omnigent 原生方式接上，見下方 |
| **規格／價格** | 4 vCPU／8 GB RAM／10 GB 磁碟，4,500 點／月（7 天試用） |

## 架構

- `chart/` 只有一個 server Deployment（:8000），Service 就是平台 tunnel 的入口
- 開機時用平台給的初始密碼建立 `admin`（`OMNIGENT_ACCOUNTS_INIT_ADMIN_*`），公開網址上
  不存在未認證的 `POST /auth/setup` 空窗
- 雲端 runner 用上游的 Kubernetes managed sandbox：server 的 ServiceAccount 只有
  namespace 內的 jobs／pods／pods/log／secrets（僅 create、delete）／events 權限，沒有
  `pods/exec`、不能讀 Secret
- 公開分享預設關閉；refresh grant 最長 365 天（讓接上的機器能自動續期）

## 把自己的機器接上 omnigent

用 omnigent 原生的方式，跟兩台區網內的機器連線一樣，平台不介入：

```bash
omnigent login <omnigent 網址>   # accounts 模式：輸入帳號密碼
omnigent host                    # 保持連線；機器會出現在 omnigent 的「Host」選單
```

### 同工作區的 PaaS pi-agent

pi-agent 可以用**內網位址**連（不經公開網路）：
`http://<omnigent release>-omnigent.<namespace>.svc.cluster.local:8000`。

1. 在 pi-agent 安裝 omnigent CLI（需要 Python 3.12，用 uv 裝在持久磁碟上）：
   ```bash
   export HOME=/data/pi-agent/home PATH=/data/pi-agent/home/.local/bin:$PATH
   curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=$HOME/.local/bin INSTALLER_NO_MODIFY_PATH=1 sh
   uv tool install --python 3.12 "omnigent==0.16.0"
   ```
2. 登入並連線：
   ```bash
   omnigent login http://<release>-omnigent.<namespace>.svc.cluster.local:8000
   PI_CODING_AGENT_DIR=/data/pi-agent omnigent host
   ```
3. **讓 omnigent 裡的 Pi 沿用 pi-web 設定好的模型**：omnigent 的 Pi 預設只認 omnigent
   自己的模型供應商；在 pi-agent 的 `~/.omnigent/config.yaml` 加上「Pi original auth」，
   Pi 就會直接用 pi 自己的登入（例如 pi-web 裡的 ChatGPT 帳號），不需要另外的 API key：
   ```yaml
   providers:
     pi-original:
       kind: subscription
       cli: pi
       default: pi
   ```

注意：
- 一台機器登記在某個 omnigent 帳號之後，換帳號重新連線會被拒絕（409）。
- `omnigent host` 目前需要手動啟動，pi-agent 重啟後要再執行一次。

## 同步

```bash
scripts/sync-from-gitea.sh              # woow-paas-charts 的 main
```

## 授權

MIT
