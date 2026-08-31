# 2026-08-31 — Initial package shape

Design log for `Woow_k3s_omnigent_package`, the k3s sibling of
`Woow_podman_omnigent_package`.

## Decisions

- **Helm chart, not Kustomize / raw YAML** — matches every other `Woow_k3s_*`
  Tier A package (`Woow_k3s_pi_agent_package`, `Woow_k3s_hermes`,
  `Woow_k3s_mcp_server`). Also gives us `helm test` hook for smoke,
  post-install hooks for auto-claim admin, and per-tenant overlays via
  `values-<env>.yaml`.

- **Independent runner PVCs, not shared with pi-agent pods** — the
  `pi-agent-N-data` PVCs on `woow-k3s` are Longhorn RWO. A live
  `pi-agent-N` pod holds each one and Longhorn refuses multi-attach
  cross-node (and warns same-node). Options considered:
    - **(chosen) Fresh per-runner PVC** — 3 × 20Gi Longhorn RWO, pi state
      starts empty; user configures providers per runner via UI or pi CLI
      exec. Simplest.
    - Sidecar into existing pi-agent pod — most invasive, changes the
      sibling `Woow_k3s_pi_agent_package` chart. Rejected.
    - Longhorn VolumeSnapshot at install time — clones pi-agent-N state
      to omnigent's PVC once, then diverges. Two-chart coordination
      overhead. Deferred.

- **3 runners for pi1/pi4/pi5** — matches the operator's naming convention
  on woow-k3s. pi2/pi3 reserved for other testing. Values list
  (`runner.hosts:`) makes this trivially extensible.

- **Cloudflared sidecar in-chart, not tailscale operator / bare Ingress** —
  every other Tier A repo uses cloudflared with cloudflare-managed
  config. One deployment, 2 replicas, credentials via Secret. Hostname
  `omnigent.woowtech.io`.

- **Post-install Job for admin claim, not initContainer on server** — the
  Job runs after server is Ready (via helm --wait), doesn't block server
  startup, has retry semantics baked into Job spec. Sibling podman version
  does the equivalent from `install.sh` (host-side curl).

- **`initContainer wait-admin-claim` on every runner Deployment** — the
  upstream runner-loop's design is "login once, if fail exec sleep
  infinity". Post-install Job racing with runner startup means the first
  runner-loop invocation loses. The initContainer polls
  `/v1/info` for `needs_setup=false` before letting runner-loop start.
  Chart-side workaround; no runner image change needed.

- **`/health` not `/healthz` for k8s probes** — same lesson as podman.
  `/healthz` is shadowed by the React SPA catch-all and returns HTML 200
  even when FastAPI is dead. `/health` returns `{"status":"ok"}` JSON only
  when API is really up. Baked into `values.yaml` as `server.healthPath`.

- **Runner image from GHCR published by podman sibling** — no image build
  in this repo. Tags are `main` (rolling) or `main-<sha>` (pinned). Only
  per-arch images exist (`-amd64`, `-arm64`) — chart defaults to amd64.

- **Recreate strategy on all Deployments/StatefulSet** — RollingUpdate
  would try to attach new pod's PVC before old pod releases it (Longhorn
  RWO blocks); Recreate is the honest choice.

## Non-goals for v0.1.0

- Multi-arch image manifest lists (sibling podman doesn't build them
  either).
- Migrating pi-agent PVCs to RWX for live state sharing.
- Sub-chart for cloudflared (kept inline for readability).
- HorizontalPodAutoscaler for server (single-writer, would collide on
  postgres).
- Ingress via Traefik / nginx (all outbound goes through cloudflared).

## Follow-ups

- **CI publish chart to GHCR OCI** as a Helm chart (`chart-releaser` or
  `helm push`). Currently `chart.yml` only lints + kubeconforms.
- **Multi-arch runner image**: get podman sibling's build.yml to emit a
  multi-arch manifest list, then drop the `-amd64` suffix here.
- **Longhorn snapshot flow** for cloning pi-agent-N state at install time
  — nice-to-have, not required for v0.1.0.
- **Live host GC**: sibling podman issue W2-HIGH-3 also applies here —
  runner pod restart leaves orphan host_id in `/v1/hosts`. UI's
  Switch-Host modal is the workaround; upstream fix is #TBD.

## Follow-ups SHIPPED

- **pgbouncer sidecar in server pod — SHIPPED 2026-08-31.** Closes the
  Resilience Test 3 caveat where an `omnigent-postgres` StatefulSet
  restart left the server's asyncpg pool holding stale sockets and
  kubelet needed ~125s of failing liveness probes to kill and restart
  the server pod. New shape: `bitnami/pgbouncer:1.24.0` runs as a
  sidecar container inside the server pod on `127.0.0.1:6432`, no
  Service (pod-local only), backed by `omnigent-postgres:5432`. Server
  `DATABASE_URL` is overridden inline in the container env
  (`postgresql+psycopg://omnigent:$(POSTGRES_PASSWORD)@127.0.0.1:6432/omnigent`)
  so the `omnigent-postgres` Secret keeps its original shape for other
  consumers (setup-admin Job, host-gc CronJob, smoke test). Pool mode
  is `session` — omnigent's SQLAlchemy async engine relies on prepared
  statements, which `transaction` / `statement` modes break.
  Target recovery on Postgres restart: **<30s** (was 125s), with no
  server-pod restart. All knobs surface under `pgbouncer:` in
  `values.yaml`; `pgbouncer.enabled=false` cleanly reverts to the
  direct Secret-backed connection (verified via `helm template … --set
  pgbouncer.enabled=false`). Sibling podman package will need the same
  fix if/when it hits the equivalent scenario.

## Follow-ups PARTIAL

- **Host GC CronJob (W2-HIGH-3 / K3S-MED-1) — dry-run-only shipped
  2026-08-31.** Added `templates/host-gc-cronjob.yaml` +
  `templates/host-gc-rbac.yaml` and `hostGc:` block in `values.yaml`.
  Runs daily at 03:00 UTC (`concurrencyPolicy: Forbid`,
  successful/failed history 3/3), logs in as admin via the existing
  `omnigent-admin` Secret, lists `/v1/hosts`, and identifies hosts
  where `status != "online"` AND `last_seen_at` older than
  `retentionMinutes` (default 60).

  **Why PARTIAL, not DONE**: endpoint discovery against
  `omnigent.woowtech.io` (`GET /openapi.json`) on 2026-08-31 shows the
  API surface for `/v1/hosts*` is read-only —
  `GET /v1/hosts`, `GET /v1/hosts/{host_id}`, plus a bunch of
  per-host POST/GET subresources (runners, harnesses,
  filesystem, worktrees, credentials). There is **no
  `DELETE /v1/hosts/{host_id}`** (nor any DELETE anywhere under
  `/v1/hosts`). So the CronJob currently only *logs* the offline
  hosts it would delete and exits 0. The DELETE branch is written
  and treats a 405 response as "server doesn't support this yet,
  no-op cleanly" — the moment upstream ships the endpoint the
  same CronJob starts pruning without a chart change (just bump
  the runner image / server image).

  Upstream ask needed: expose `DELETE /v1/hosts/{host_id}` (idempotent,
  returns 204 on success and 404 if already gone). Track that
  issue; when it merges, flip this section to DONE and remove the
  405-tolerance branch in the template.

- **RBAC**: the CronJob talks to `omnigent-server` (JWT), not
  kube-apiserver, so no `Role`/`RoleBinding` was created. Only a
  dedicated `ServiceAccount omnigent-host-gc` with
  `automountServiceAccountToken: false` for audit separation.
  Documented in `templates/host-gc-rbac.yaml`.
