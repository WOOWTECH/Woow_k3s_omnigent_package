# Draft upstream issue — chat input silently dropped on pi-native session

Target: https://github.com/omnigent-ai/omnigent/issues (do NOT file yet — draft only)

---

## Title

`pi-native web-chat input never reaches Pi terminal when a resource_event lands ahead of the user message (deployment-topology-sensitive race)`

## Environment

- Upstream commit: `main` (post-v0.11.0), verified against
  `/tmp/omnigent-upstream` @ 2026-08-31
- Server: `ghcr.io/omnigent-ai/omnigent-server:latest`
- Runner: multi-arch runner image built from the same `main` branch
  (image tags: `ghcr.io/woowtech/woow-omnigent-runner:main` for the
  reporter, but the same behaviour holds on the upstream runner image
  because none of the relevant code paths under `omnigent/runner/app.py`
  or `omnigent/pi_native_bridge.py` were re-vendored)
- Harness: `pi-native` (built-in native TUI wrapper), one pi CLI running
  in-container in the runner pod's tmux
- Postgres: 16-alpine, single instance (Longhorn PVC)
- Two topologies compared:
  - **Broken:** k3s deployment behind Cloudflare Tunnel — browser →
    cloudflared → cluster nginx → `omnigent-server:8000` (SPA POST path
    goes over WAN + TLS + HTTP/2 buffering at the CF edge). Runner ↔
    server is in-cluster (`OMNIGENT_SERVER_URL=http://omnigent-server:8000`)
    over the WS tunnel — no CF in this leg.
  - **Working:** podman on a single host on tailnet — browser reaches
    the server via `tailscale serve` on the same LAN, effectively
    loopback + tailnet. Same runner image, same server image, same
    Postgres.

## Symptoms (verbatim runner logs)

Session ID `conv_<id>` is a fresh pi-native chat. User types "hello"
in the web UI. Session snapshot is created; the URL becomes `/c/<id>`;
the user bubble echoes in the SPA and stays in pending state indefinitely.
No assistant reply, no pi output.

Runner logs (in order):

```
INFO post_session_events: conv=<id> type=message active=False buffer_len=0 content_types=['input_text'] model_override=None
INFO HTTP Request: GET /v1/sessions/<id>/items?limit=1&order=desc "HTTP/1.1 200 OK"
INFO HTTP Request: GET /v1/sessions/<id>/items?limit=100&order=asc "HTTP/1.1 200 OK"
WARN _convert_raw_items_to_input: skipped 1 items with types: ['resource_event']
INFO _convert_raw_items_to_input: 1 raw items → 0 converted (compaction_idx=None)
INFO post_session_events: starting background turn conv=<id>
INFO _run_turn_bg: conv=<id> history_msgs=1 content_summary=["msg(user, blocks=['input_text'])"]
INFO HTTP Request: POST http://harness.local/v1/sessions/<id>/events "HTTP/1.1 200 OK"
```

Nothing further. No `TurnComplete`, no assistant `message_end`, no
`external_conversation_item` echo from the pi extension. The session
hangs.

The same session flow on the podman deployment (same image tags,
tailnet-direct server URL) completes in 30–60 s with an assistant reply.

## Where the message flow goes wrong — code trace

For clarity I number the steps against the upstream tree at
`/tmp/omnigent-upstream/omnigent`.

1. **SPA → server:** `POST /v1/sessions/{id}/events` with
   `{"type":"message","data":{"content":[{"type":"input_text",...}]}}`
   lands at `server/routes/sessions/routes_events.py::post_event`
   (line 392).

2. **Server dispatches to native branch:** because the session's harness
   resolves to `pi-native`, the route calls
   `_dispatch_session_event_to_runner_impl` in
   `server/routes/_sessions/orchestration.py` (line 5458). At
   line 5549 the native-terminal branch fires — the user message is
   **intentionally not persisted** server-side (single-writer invariant
   — the pi extension is the sole writer of user-message items back
   through `external_conversation_item`).

3. **Terminal-ready probe:** the branch first calls
   `_ensure_native_terminal_ready` (line 3847) which posts to the
   runner's `/v1/sessions/{id}/resources/terminals` with
   `persist_resource_event: True`. That call causes the runner to
   auto-create the pi terminal (`_auto_create_pi_terminal` in
   `runner/native/orchestration.py` line 2060) AND persist a
   `resource_event` on the server.

4. **Server forwards user message to runner:**
   `_forward_native_terminal_message` (`orchestration.py` line 4189)
   does `runner_client.post(f"/v1/sessions/{session_id}/events", ...)`.

5. **Runner's `post_session_events` (`runner/app.py` line 7659):**
   because `conv not in _session_histories` on the first turn, line
   7797 calls `_load_history_as_input(conv)` — a paged GET against the
   server's `/v1/sessions/{id}/items?limit=100&order=asc`. What it
   fetches at this moment is `[resource_event]` (the terminal
   creation from step 3), which
   `_convert_raw_items_to_input` (line 4070) correctly drops (it only
   converts `message | function_call | function_call_output | error`
   items — see the allow-list at line 4120).

6. The runner then appends the just-received user message to the
   empty converted-history list, sets
   `_session_histories[conv] = [user_msg]`, and spawns
   `_run_turn_bg` (line 7822).

7. **`_run_turn_bg_setup_and_stream` (line 6497)** builds `harness_body`
   from `_session_histories[conv]` (line 6697) — history is a
   single-element list containing the user message — and streams it
   into `_stream_message_to_harness` (line 6863), which POSTs to
   the per-conversation harness FastAPI subprocess at
   `http://harness.local/v1/sessions/<id>/events`. That subprocess
   is `omnigent.inner.pi_native_harness:create_app`
   (`inner/pi_native_harness.py`), which wraps
   `PiNativeExecutor` (`inner/pi_native_executor.py`).

8. **`PiNativeExecutor.run_turn` (`inner/pi_native_executor.py`
   line 76):** extracts the latest user text and calls
   `enqueue_user_message(bridge_dir, text)` — writes an atomic
   `inbox/{ordinal}_msg_{uuid}.json` file under
   `~/.omnigent/pi-native/<sha256(session_id)>/inbox/`. Returns
   `TurnComplete(response=None)`.

9. **Pi extension polls inbox:** `omnigent_pi_native_extension.js`
   scans `inbox/*.json`, dedups by payload id, deletes each file, and
   invokes `pi.sendUserMessage(text)`. This is what triggers the pi
   model call and eventually a `message_end` event that the extension
   POSTs back to the server as `external_conversation_item`.

Steps 1–7 are visible in the reporter's log. Step 8 is inferred from the
`200 OK` on the harness POST (`PiNativeExecutor.run_turn` yields
`TurnComplete` and the ExecutorAdapter closes the SSE stream with
`[DONE]`; the AsyncGenerator's exception path would have surfaced as a
non-2xx). **Step 9 is where the reporter observes silence** — no pi
output, no `external_conversation_item` echo, no `session.status` edge.

## Hypotheses

Two plausible causes, both consistent with the observed logs and with
the topology delta:

### H1 — SPA-POST buffering race pushes the resource_event ahead of the message on the server-side timeline (but does NOT explain the pi silence by itself)

Cloudflare's HTTP/2 edge is known to buffer client POST bodies. If the
SPA's POST to `/v1/sessions/{id}/events` is buffered enough that the
runner's `_ensure_native_terminal_ready` call and the resource_event
persist RACE ahead of the message-forward call (they don't — see step 3
above: they're serialized inside the same `_dispatch_session_event_to_runner_impl`
coroutine), we would see exactly the observed
`_convert_raw_items_to_input: 1 raw items → 0 converted` warning. The
warning IS expected on the first turn of any native-terminal session
because the terminal-create legitimately writes a resource_event first,
and this branch never persists the user message anyway.

**So H1 is not root-cause of the pi hang** — it only explains the
noisy log line. The runner still correctly builds
`_session_histories[conv] = [user_msg]` and forwards it. The 200 OK on
the harness POST confirms `enqueue_user_message` ran. On the podman
side the same log line appears too — the reporter's earlier debugging
noted it but noise, not signal.

### H2 — Pi extension polling loop failure mode specific to k3s topology

The delta that actually matters is what happens between step 8 (file
written to `inbox/`) and step 9 (extension consumes and calls
`pi.sendUserMessage`). Candidates that would produce the exact reporter
symptoms (harness 200 OK, no pi reply, indefinite pending):

- **Filesystem visibility**: on the runner pod the inbox lives at
  `Path.home() / ".omnigent" / "pi-native" / <sha>` — resolves to
  `/root/.omnigent/pi-native/<sha>` when the runner container runs as
  root. The pi CLI is spawned inside the same container's tmux via
  `launch_required_terminal` with `os_env.type: caller_process` and
  the agent-spec sandbox (default `linux_bwrap` if unset —
  `omnigent/inner/sandbox.py::_default_sandbox_for_platform` line 1172).
  On k3s pods without `CAP_SYS_ADMIN` / user namespaces, `bwrap` inside
  the pi CLI's own subprocess spawns may silently fall back to a mount
  namespace that doesn't include `/root/.omnigent/pi-native`. On the
  podman `UserNS=keep-id:uid=1000,gid=1000` deployment the extension
  runs with the full host mount view. **This would explain
  same-image / different-topology divergence with no upstream code
  change needed** — it's an operator-side kernel-cap gap.

- **Pi extension outbound POST auth wedge**: the extension needs to POST
  `external_conversation_item` back to the server via the URL baked into
  `config.json` (`serverUrl` = `RUNNER_SERVER_URL` — see
  `runner/native/orchestration.py` line 2117). On k3s that URL is
  `http://omnigent-server:8000` (in-cluster). If the extension's outbound
  bearer / routing headers fail on this URL (e.g. missing binding-token
  path in a k3s pod) the message DID enter Pi, Pi replied to itself,
  but the reply couldn't post back — so from the browser side it looks
  identical to "input never reached Pi". Distinguishable by checking
  `podman logs -f runner` for the pi CLI's own stdout: if it says
  "hello" back, this is the failure mode; if it says nothing about the
  user's message, this is the filesystem-visibility mode.

### Which one? — diagnostic asks

- Please attach output of, on the runner pod:
  ```
  kubectl -n omnigent exec deploy/omnigent-runner-<host> -c runner -- \
    ls -la /root/.omnigent/pi-native/*/inbox/ 2>&1
  kubectl -n omnigent exec deploy/omnigent-runner-<host> -c runner -- \
    ps auxf | grep -E '(pi|tmux)'
  ```
  right after a stuck message is sent. If inbox is empty, the extension
  IS polling and consuming (mode B — outbound POST wedge). If inbox
  has orphan `msg_*.json` files, extension isn't seeing them (mode A —
  filesystem visibility).

- And the pi CLI's own log lines from the tmux pane. `omnigent host`
  inherits stdout, so `kubectl logs deploy/omnigent-runner-<host>` will
  show them; look for `pi.sendUserMessage` or
  `handling user_message payload id=` lines from the extension
  around the timestamp of the stuck message.

## Suggested fix (upstream — belt and suspenders regardless of which H)

The runner has an in-memory `_session_histories` cache and the pi extension
has a filesystem-polling inbox. Neither has a **retry / backoff** on the
message-delivery side, and neither surfaces to the operator when a
message was enqueued to the inbox but not consumed within N seconds.
Two upstream-only changes would turn this failure from "silent
indefinite hang" into "clear diagnostic":

1. **Ack loop on `enqueue_user_message`.** Have the extension write a
   sibling `<msgid>.ack` file (or POST back an ack event) when it
   consumes an inbox payload. `PiNativeExecutor.enqueue_session_message`
   / `run_turn` could wait up to N seconds for the ack and yield an
   `ExecutorError` — the runner then publishes a
   `session.status = error` and the user sees a real error instead of a
   pending spinner. Today the executor yields `TurnComplete` the instant
   the file lands on disk, with no delivery confirmation
   (`inner/pi_native_executor.py` line 102).

2. **Runner-side inbox watchdog.** After `enqueue_user_message` returns,
   the runner could stat the inbox after ~10 s; if `<msgid>.json` is
   still there, log a warning and publish a session-level notice
   (`_post_pi_native_credential_warning` already exists as a template —
   `runner/native/orchestration.py` line 2274).

3. **Subscribe rather than poll for post-turn history.** Runner's
   `_load_history_as_input` (line 4006 in `runner/app.py`) fires two
   HTTP GETs per new session even when it's about to append the user
   message to an empty list. On a session that never had prior turns
   the resource_event fetch is pure overhead. Skipping it for native
   sessions (`if is_native_harness(harness_name): return []` — the
   `_convert_raw_items_to_input` warning at line 4170 is then also
   gone) would eliminate the noise-warning that misleads operators
   into thinking THIS is the bug. Cleaner: keep the fetch but log at
   DEBUG, and treat any non-message polled items as informational.

## Comparison to working podman deployment

The reporter's podman sibling (`Woow_podman_omnigent_package`) uses the
exact same runner image and the exact same pi CLI wrapper
(`/usr/local/bin/pi-code`). Both deployments:

- share the same `PI_CODING_AGENT_DIR=/data/pi-agent`,
- inherit the same `OMNIGENT_PI_PATH=/usr/local/bin/pi-code`,
- run the runner and pi CLI in the same container (`ExecutorAdapter`
  spawns the harness subprocess in-process; pi CLI runs in a
  same-container tmux).

Deltas that could explain the working-vs-broken split:

1. Podman quadlet sets `UserNS=keep-id:uid=1000,gid=1000` — the
   container's uid/gid map matches the host so `bwrap`'s user-namespace
   requirement is satisfied without kernel-cap gymnastics.
2. K3s runs the pod with the default Kubernetes user-ns disabled (unless
   `spec.securityContext.userNamespaces` is set on 1.30+), so `bwrap`
   inside the pi CLI's shell-tool spawns may fall back or fail.
3. Client-side POST to `/events` traverses cloudflared on k3s and
   `tailscale serve` on podman — but this leg is orthogonal to
   step-8/step-9 above and only affects the runner's initial ingest
   timing (H1 above, ruled out).

## Links back to reporter repos

- k3s package under test: https://github.com/WOOWTECH/Woow_k3s_omnigent_package
- Working podman sibling: https://github.com/WOOWTECH/Woow_podman_omnigent_package
- Reporter operator context: `/tmp/Woow_k3s_omnigent_package/docs/plans/2026-08-31-initial-package.md`

## Ask

Two questions for maintainers:

- Is the pi extension's inbox poller expected to work when the pi CLI
  runs inside a mount namespace that doesn't include the runner's
  `$HOME/.omnigent/pi-native` prefix? If not, the runner would ideally
  either (a) mount the bridge into the pi cwd or (b) fail loudly at
  terminal-create rather than fail silently at first message.
- Would a PR adding the ack + watchdog + native-harness skip in
  `_load_history_as_input` be welcome, or is there a design reason
  the current fire-and-forget shape is preferred?

Happy to bisect further with the diagnostic asks above and, if it's
the mount-namespace hypothesis, contribute a chart-level PSP /
`securityContext.userNamespaces` guide for k3s operators alongside the
upstream fix.
