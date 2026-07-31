# Coding workspace relay

The coding workspace relay is a lightweight HTTP server that runs on the `chat`
queue worker and serves coding-session file and diff reads to web pods. It solves
the multi-pod problem: `$SYRUS_DATA_ROOT/chat-workspaces/` is on the worker pod's
local disk, so the web pod cannot read it directly. The relay uses the same
pattern as `TerminalRelay`.

## Architecture

The worker binds a TCP port on startup and records its `host:port` in
`chat_sessions.coding_relay_address` when a coding checkout is active. Web pods
read that address from the DB and proxy the three coding sidebar endpoints to the
worker. Request auth is a per-session bearer token stored in
`chat_sessions.coding_relay_token` (generated once per checkout, cleared on
reclaim or cancel).

These routes are served by the relay:

| Route | Returns |
|---|---|
| `GET /workspace/files?session_id=N[&ref=<sha>]` | File tree for the live checkout or a commit |
| `GET /workspace/commits?session_id=N` | Up to 50 recent commits on the checkout branch |
| `GET /workspace/file?session_id=N&path=<rel>[&ref=<sha>]` | File content from the live checkout or a commit |
| `GET /workspace/diff?session_id=N&mode=<cumulative\|turn>[&ref=<sha>]` | Live checkout diff or a single-commit diff |

## Configuration

### `SYRUS_WORKSPACE_RELAY_PORT`

The TCP port the relay listens on (default `9283`). Set this on the worker if the
default port conflicts with something already running on the host.

### `SYRUS_TERMINAL_HOST`

The hostname or IP that the web container uses to reach the worker relay. The
coding relay reuses the same env var as the terminal relay:

| Environment | Setting |
|---|---|
| Bare-metal / local dev | Leave blank; relay defaults to `127.0.0.1` |
| Docker Compose | Set to the worker service name (e.g. `worker`) |
| Kubernetes | Set from the Downward API field `status.podIP` on worker pods |

### `SYRUS_ROLE=worker`

The relay only starts when `SYRUS_ROLE=worker` is set on the worker process.
This is already set in the Docker image's worker command (`./bin/jobs`) and in
`Procfile.dev`. If you run a custom worker entry point, ensure this env var is
present.

## Relay lifecycle

- The relay starts once when the worker process boots (via `config/initializers/chat_workspace_relay.rb`).
- `coding_relay_address` and `coding_relay_token` are written to `chat_sessions`
  when `ensure_coding_checkout!` runs and the relay is up.
- Both columns are cleared on `reclaim_coding_checkout!` or `cancel_coding_checkout!`.
- The chat payload exposes `coding_relay_ready: true` once the relay address is
  recorded, so the UI can show a loading state while the relay warms up.

## Pre-turn checkout and prep visibility

`ChatTurnJob` calls `ChatWorkspace.ensure_coding_checkout!` before building the
Coding Mode prompt. That method creates the writable checkout on first use,
restores a reclaimed checkout when needed, and enqueues `ChatWorkspacePrepareJob`
asynchronous repository prep after creation or restoration. The agent does not
need to initialize the workspace manually; its first step should be normal
inspection/editing inside the reported checkout path.

`chat_sessions` stores the latest prep snapshot in
`coding_checkout_prepare_status`, `coding_checkout_prepare_started_at`,
`coding_checkout_prepare_finished_at`, and `coding_checkout_prepare_failure`.
The Coding Mode prompt and chat environment snapshot report the checkout path,
current branch/ref, default branch, and prep status (`queued`, `running`,
`succeeded`, `failed`, or `unknown`) so setup failures remain visible even
though they do not block the agent turn.

## Multi-worker note

The chat queue must run on exactly one worker pod. Chat workspaces are on local
disk and the relay address recorded in the DB points to that pod. Do not put the
`chat` queue on multiple pods or scale it past one replica. See `multi_worker.md`
for the full constraint.
