# Coding workspace relay

The coding workspace relay is a lightweight HTTP server that runs on the `chat`
queue worker and serves coding-session file and diff reads to web pods. It solves
the multi-pod problem: `$SYRUS_DATA_ROOT/chat-workspaces/` is on the worker pod's
local disk, so the web pod cannot read it directly. The relay uses the same
pattern as `Terminal::Relay`.

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

## Relay refresh routing (`workspace_storage_key`)

`chat_sessions.coding_relay_address`/`coding_relay_token` are opportunistic:
they only get written by whichever worker most recently confirmed the
checkout on local disk (`ChatWorkspace#write_relay_credentials!`, called from
`ensure_root!`, `attach_repository!`, `ensure_coding_checkout!`, and
`refresh_relay_credentials!`), and `ChatsController` clears both columns on any
transient relay connection failure (worker restart, pod reschedule, a brief
network blip — not just an actually-missing checkout). `ChatCodingRelayRefreshJob`
is the repair path for that cleared state.

That same `write_relay_credentials!` call also stamps
`chat_sessions.workspace_storage_key` with `WorkerStorageIdentity.key` — the
identity of the worker whose local disk holds the checkout. When
`ChatsController#schedule_coding_relay_refresh!` enqueues the refresh job, it
routes it onto that worker's own `resume-<workspace_storage_key>` queue
(the same storage-affinity mechanism `RunJob` uses for retry-from-failed-step)
instead of the plain `chat` queue, so the refresh lands on the worker that can
actually see the checkout. A chat session with no `workspace_storage_key` yet
(no checkout has ever been confirmed anywhere) falls back to the plain `chat`
queue — there is nothing to route to.

`ChatCodingRelayRefreshJob` and `ChatWorkspace#refresh_relay_credentials!`
never re-clone: the checkout may hold uncommitted agent work, and a silent
re-clone would destroy it. If the job is correctly routed to the worker that
recorded the checkout and the checkout is still missing there (genuinely
lost — wiped disk, evicted PVC), it logs an error identifying the chat session
and worker, clears the (already-stale) relay credentials, and stamps
`coding_checkout_prepare_status: "workspace_lost"` with a `coding_checkout_prepare_failure`
message instead of silently no-opping. A chat landing on a worker other than
the one recorded in `workspace_storage_key` (should not happen given the
routing above, but is not treated as proof of loss) logs a warning and leaves
the session untouched.

## Pre-turn checkout and prep visibility

`ChatTurnJob` calls `ChatWorkspace.ensure_coding_checkout!` before building the
Coding Mode prompt. That method creates the writable checkout on first use,
restores a reclaimed checkout when needed, and enqueues `ChatWorkspacePrepareJob`
asynchronous repository prep after creation or restoration. The agent does not
need to initialize the workspace manually; its first step should be normal
inspection/editing inside the reported checkout path.

After an operator accepts `submit_coding_changes`, `CodingHandoffConfirmJob`
captures the current committed HEAD to the immutable handoff branch and starts
the `coding_handoff` workflow. After both steps succeed, the chat checkout stays
at the submitted HEAD so the operator and agent can continue iterating from the
same committed state. The next continuous `submit_coding_changes` uses that
prior submitted HEAD as its stack base and records a `JobDependency` on the
prior handoff Job. Capture failures likewise leave the checkout untouched, so
local work remains available for recovery.

`reset_workspace` is the explicit fresh-main escape hatch. With
`confirm_discard: true`, it resets the checkout to `origin/<default_branch>`,
removes untracked and ignored files, clears the uncommitted-work flag, records
the Coding Mode submit lineage as fresh-main, and enqueues prep again. The next
handoff from that reset checkout starts a new independent stack.

`chat_sessions` stores the latest prep snapshot in
`coding_checkout_prepare_status`, `coding_checkout_prepare_started_at`,
`coding_checkout_prepare_finished_at`, and `coding_checkout_prepare_failure`.
The Coding Mode prompt and chat environment snapshot report the checkout path,
current branch/ref, default branch, and prep status (`queued`, `running`,
`succeeded`, `failed`, or `unknown`). Ordinary Coding Mode turns can still see
and recover from setup failures, but coding Chat Goal continuations wait until
the checkout exists and prep has reached `succeeded`. If prep fails while a goal
continuation is waiting, Syrus records a readiness system event instead of
waking the agent into a half-prepared checkout.

## Multi-worker note

The chat queue must run on exactly one worker pod. Chat workspaces are on local
disk and the relay address recorded in the DB points to that pod. Do not put the
`chat` queue on multiple pods or scale it past one replica. See `multi_worker.md`
for the full constraint. `workspace_storage_key` routing (above) makes relay
*refresh* resilient to that constraint being violated — a scaled-out `chat`
queue no longer strands the refresh on a pod without the checkout — but it does
not make the rest of Coding Mode (checkout creation, prep, `ChatTurnJob`) safe
to run across more than one `chat`-queue replica; the single-pod requirement
still applies there.
