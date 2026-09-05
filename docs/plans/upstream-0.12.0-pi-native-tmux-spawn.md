# Upstream omnigent 0.12.0 pi-native tmux spawn deep-dive

Source: `https://github.com/omnigent-ai/omnigent` @ `main` (post-v0.12.0, `pyproject.toml` = `0.13.0.dev0`, CHANGELOG confirms `v0.12.0` section on 2026-09-01). Shallow clone at `/tmp/omnigent-upstream-v012`.

## 1. Who creates the tmux server at `/tmp/omnigent-terminal-*/tmux.sock`?

The socket path is generated **and** the tmux server is spawned inside a single Python call chain — no CLI, no external event, no env-flag gate.

Chain (bottom-up):

1. **Path** — `omnigent/inner/terminal.py:2033-2034` `create_terminal_instance()`:
   ```python
   private_dir = Path(tempfile.mkdtemp(prefix=_TERMINAL_DIR_PREFIX))   # /tmp/omnigent-terminal-XXXX
   socket_path = private_dir / "tmux.sock"
   ```
   `_TERMINAL_DIR_PREFIX = "omnigent-terminal-"` (line 67).

2. **Spawn** — `omnigent/inner/terminal.py:1046-1187` `TerminalInstance.launch()`. Builds `tmux -S <socket> -f /dev/null <opts> new-session -d -s main -x 80 -y 24 -c <cwd> <inner_str>` (lines 1147-1172) and execs it (line 1174-1179). RC≠0 raises `RuntimeError` (line 1181-1184).

3. **Registry** — `omnigent/terminals/registry.py:160-243` `TerminalRegistry.launch()` calls `create_terminal_instance(...)` (line 221-229) then immediately `await created.instance.launch(cwd=created.cwd)` (line 230), then `if not await created.instance.is_alive()` → raise (line 231-243). So a tmux server that dies BEFORE the ~ms-old `is_alive()` probe is caught; one that dies AFTER is not.

4. **Session-resource seam** — `omnigent/runner/resource_registry.py:915-1014` `SessionResourceRegistry.launch_required_terminal()` → `_launch_terminal_with_lifecycle` (line 998-1006) delegates to `TerminalRegistry.launch`.

5. **Pi-native adapter** — `omnigent/runner/native/orchestration.py:2061-2281` `_auto_create_pi_terminal()`. Line 2223-2242 calls `resource_registry.launch_required_terminal(session_id=..., terminal_name="pi", session_key="main", ...)`. Line 2250 emits the `"Auto-created pi terminal for session %s with extension %s"` log — this fires ONLY after the whole chain returned without exception.

6. **Trigger** — `omnigent/runner/app.py:3836-4060` (the `POST /v1/sessions` handler on the runner). When `native_coding_agent_for_harness(harness_name)` returns pi, it calls `_launch_native_terminal("pi-native", ctx, ensure_locks=_pi_terminal_ensure_locks, resolve_agent_spec=lambda: _resolve_session_agent_spec(session_id))` (line 4044-4060) which walks to `_launch_pi` → `_auto_create_pi_terminal`.

**Spawn is NOT triggered by any API call, env, or CLI flag**. It happens synchronously inside the runner's `POST /v1/sessions` handler when the harness resolves to pi-native.

## 2. What did 0.11.0 do differently?

Trace above hasn't changed shape between 0.11 and 0.12 — the same `_auto_create_pi_terminal` / `TerminalRegistry.launch` / `TerminalInstance.launch` chain existed. What changed in v0.12.0 (from `CHANGELOG.md` lines 8-160) that touches this path:

- **PR #3929** (line 21): the "authored instructions accepted but have no delivery channel on this harness" warning was ADDED. Pi-native is explicitly `instruction_delivery=_ID.NOT_DELIVERED` in `omnigent/harness_plugins.py:379`. This warning is BENIGN — not the tmux failure cause.
- **PR #5183** (line 52): "Relaunching a session no longer leaks the previous runner process (and its terminal pane) on the host." Added `_OWNER_PID_FILENAME` + `reap_orphaned_terminals()` (`omnigent/inner/terminal.py:703-770`), called at runner startup.
- **PR #5390** (line 78): "Terminal sessions no longer freeze after a transient tmux probe failure." Introduced the 3-consecutive-failure exit in `start_idle_watcher` (`omnigent/inner/terminal.py:1433-1468`) — the exact "ERROR inner.terminal: tmux unavailable after 3 consecutive probes" you see.
- **PR #5484** (line 116): "**Breaking** — Web terminals now use one control-mode attach path; legacy PTY transport configuration has been removed." This is the meaningful behavioural change.

Neither the pi extension nor `omnigent run` was ever responsible for spawning tmux — pi didn't self-spawn; it's always been the runner. 0.11 pi 0.83.0 succeeded because pi's own launch didn't crash inside the tmux pane. **In 0.12 with pi 0.85.1 something inside the pane exits before the idle watcher can complete 3 probes** — but the runner still records "Auto-created pi terminal" because tmux itself launched fine and the initial `is_alive()` check passed before pi died.

## 3. Config / env / CLI that would fix this?

None. Grepped for `OMNIGENT_PI_AUTO_SPAWN`, `OMNIGENT_TMUX_*`, `PI_NATIVE_*` — the only relevant knob is `OMNIGENT_PI_PATH` / `OMNIGENT_PI_NATIVE_BRIDGE_DIR` (both already correctly set on k3s). `omnigent host` has no `--auto-spawn-terminal` flag; there is no `omni setup pi-native` step. `_ensure_pi_terminal_on_runner` (`omnigent/pi_native.py:506-520`) POSTs `ensure_native_terminal:true`, but that's for the CLI `omnigent pi` path — the web-UI path already spawns via `_launch_native_terminal` in the session-create handler (app.py:4053).

The `omnigent pi` CLI path DOES POST an explicit "ensure" request after session creation (`omnigent/pi_native.py:441`). The web-UI/API path does NOT — it relies on the in-handler `_launch_native_terminal`. Both funnel to the same `_auto_create_pi_terminal`, so this is a red herring, not a missing step.

**Real gap on our side**: pi-code 0.85.1 dies in the tmux pane after `TerminalRegistry.launch()` returns success. The runner never streams pi's stderr — it goes to the tmux pane, and once tmux dies the pane bytes are gone. There is no upstream env to force a `keep_alive_after_exit` on pi-native; the spec at `orchestration.py:2229-2241` does not set it, so `pane-died detach-client -a` (terminal.py:1142-1146) is not installed and remain-on-exit is off → pi exit ⇒ tmux exit ⇒ empty socket.

## 4. `agent instructions not delivered ... delivery=not-delivered`

Fully expected and unrelated. `omnigent/harness_plugins.py:379` declares pi-native with `instruction_delivery=_ID.NOT_DELIVERED` (unchanged concept, warning added in PR #3929). The warning source is `omnigent/runner/app.py:7388-7394` and `:7975-7981`. It fires whenever the harness's `HarnessCapabilities.instruction_delivery` is `NOT_DELIVERED` or `UNKNOWN`. No POST-events channel exists for pi-native instruction delivery in 0.12.0; the change is purely observability. Nothing for our runner to implement.

## Concrete fix recommendation

**Path (a) — runner-side change we can make ourselves**: capture pi-code's stderr so we can see WHY it exits. Two options, in order of leverage:

1. **Before it dies**: on the k3s pod, run pi-code by hand once with EXACTLY the args and env the runner uses. Read the extension the runner materialises at `/omnigent-home/.omnigent/pi-native/<sha256>/`:
   ```sh
   HOME=/omnigent-home PI_CODING_AGENT_DIR=/data/pi-agent \
     PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
     /usr/local/bin/pi-code \
       --extension /omnigent-home/.omnigent/pi-native/<sha256>/omnigent_pi_native_extension.js \
       --session-dir /omnigent-home/.omnigent/pi-native/<sha256>/sessions \
       --approve
   ```
   The stderr/stdout from that run is the exit reason the runner is hiding. Ninety percent likely pi 0.85.1 barfs on a missing/invalid config or an unroutable model — see `_pi_native_credentials` provider resolution in `orchestration.py:2189-2217` where `credential_warning` is surfaced only if a provider IS resolved. A `pi /login` on the pod, or forcing `pi-code --model <known-good>` via session `terminal_launch_args`, is the most likely fix.

2. **Belt & braces**: after fix #1, set the pi terminal spec's `keep_alive_after_exit=True` in our fork of orchestration.py:2229-2241 (or patch at deploy time). That installs the `pane-died detach-client -a` hook (terminal.py:1142-1146) so pi's exit no longer kills tmux, giving the idle watcher a stable pane and preserving pi's exit output for one more capture-pane cycle. Upstream never enables this for pi-native, so this is a local downstream patch.

If step 1's stderr shows a real pi bug (not a config), file the issue with the exact stderr — but the tmux-spawn contract itself is fine on the omnigent side.

## Key file references

- `omnigent/inner/terminal.py:67, 1046-1187, 1433-1468, 2030-2123` — socket, launch, watcher, factory
- `omnigent/terminals/registry.py:160-266` — registry launch + is_alive gate
- `omnigent/runner/resource_registry.py:915-1014` — session-scoped launch seam
- `omnigent/runner/native/orchestration.py:475-936, 1876-1908, 2061-2281, 7728-7737, 7870-7969` — pi launch config, args builder, `_auto_create_pi_terminal`, `_launch_pi`, `_launch_native_terminal`
- `omnigent/runner/app.py:3836-4060, 7376-7396, 8025-8060, 9280-9297` — POST /v1/sessions native branch, warning site, `_ensure_native_terminal`
- `omnigent/pi_native.py:441, 506-520` — CLI-only `_ensure_pi_terminal_on_runner`
- `omnigent/pi_native_bridge.py:29-133, 291-330` — bridge dir + extension write
- `omnigent/harness_plugins.py:366-380` — pi-native capabilities incl. `instruction_delivery=NOT_DELIVERED`
- `CHANGELOG.md:8-160` — v0.12.0 change window (PRs #3929, #5183, #5390, #5484 are the pi/tmux-adjacent ones)
