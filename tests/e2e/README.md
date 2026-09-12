# Omnigent 0.11.0 Web UI — Playwright E2E (k3s)

Self-contained Playwright + TypeScript E2E suite for the Omnigent 0.11.0 Web UI
served by the `Woow_k3s_omnigent_package` Helm chart, fronted by cloudflared at
`https://omnigent.woowtech.io`.

## Run

```
cd tests/e2e
npm ci
npm run install-browsers
OMNIGENT_BASE_URL=https://... OMNIGENT_ADMIN_PASSWORD=... npm test
```

To exercise the chat round-trip + Automations suites, the runner PVCs must
already be seeded with a warm pi-agent snapshot (see `scripts/seed-pi-from.sh`
in the repo root). Once the seed has completed at least once, opt in with:

```
OMNIGENT_PI_SEEDED=1 npm test
```

Without `OMNIGENT_PI_SEEDED=1`, chat-send and Automations-modal tests skip so a
fresh cluster doesn't fail the whole suite before its first seed.

Environment variables (all optional; defaults are for the k3s prod deployment):

| var                        | default                                                                 |
| -------------------------- | ----------------------------------------------------------------------- |
| `OMNIGENT_BASE_URL`        | `https://omnigent.woowtech.io`                                          |
| `OMNIGENT_ADMIN_USERNAME`  | *(required — no default; read it from the `omnigent-admin` Secret)*     |
| `OMNIGENT_ADMIN_PASSWORD`  | *(required — no default; read it from the `omnigent-admin` Secret)*     |
| `OMNIGENT_PI_SEEDED`       | *(unset — chat/automation tests skip until set to `1`)*                 |

## Suites

- `specs/smoke.spec.ts` — unauthenticated health/info + login flow
- `specs/settings.spec.ts` — settings shell (account/appearance/git/shortcuts/members/policies/sharing/archived)
- `specs/chat.spec.ts` — new session round-trip *(seeded-only)*, harness picker asserting 3 k3s pi runners, Ctrl+N (serial)
- `specs/inbox-automations.spec.ts` — inbox empty state + automations New task modal *(seeded-only)*
- `specs/rwd.spec.ts` — 375x812 mobile hamburger + 1440x900 desktop shell
- `specs/k3s-hosts.spec.ts` — asserts `/v1/hosts` returns >=3 online runners named `omnigent-runner-pi{1,4,5}-*`

## Notes

- Chromium-only. arm64/amd64 CI friendly.
- `workers: 1` — the sidebar recent-session list races if two tests create sessions
  in parallel.
- No mock/fixture data. Tests hit the real cluster through cloudflared, including
  a real Pi model round-trip in `chat.spec.ts` when `OMNIGENT_PI_SEEDED=1`
  (allowed up to 90s).
- One known-issue marker: `@known-issue omnigent-server-healthcheck-shadowed` on the
  `/healthz` test — the endpoint currently returns SPA HTML instead of JSON; we only
  assert status 200 until the server route is un-shadowed.
- k3s topology: the Helm chart deploys 3 runner Deployments (`omnigent-runner-pi1`,
  `-pi4`, `-pi5`), one Pod each. Older ReplicaSet Pods may linger as offline
  entries in the host list; the `k3s-hosts` and harness-picker tests tolerate
  extras and only enforce the online-count floor.

## Provenance

Ported from `Woow_podman_omnigent_package/tests/e2e/` on **2026-08-31**. The
podman suite was generated from a chrome-devtools MCP walk against Omnigent
**0.11.0** on the woow-openclaw runner; the k3s port adapts topology-sensitive
assertions (3 hosts, `omnigent.woowtech.io` base URL, seed-gated chat).
