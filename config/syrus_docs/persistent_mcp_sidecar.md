# Persistent MCP sidecar

Workflow agents normally talk to Syrus over a stdio MCP server that is spawned
fresh for every run (`Mcp::Sidecar`, see `bin/syrus-mcp-sidecar`). Chat agents
use the persistent daemon when it is available; the old direct chat stdio
sidecars still exist for specialized internal callers, but generated
agent-visible chat MCP config no longer points at them because they need Rails
boot secrets. Booting one of those Rails sidecars from scratch each time is
expensive and can fail under load.

`persistent_mcp_sidecar` is a labs feature (default on) gating a
worker-local daemon that boots Rails once and stays up, instead of once per
run or chat turn. The flag is visible in Admin → Features and is also
toggleable via Rails console (see "Toggling" below), so operators can turn it
off without shelling into a worker when they need to fall back to per-run
workflow stdio sidecars. `WorkflowMcpTransportSelector` and
`ChatMcpTransportSelector` each decide, per workflow agent invocation or chat
turn respectively, whether to route that invocation's MCP traffic to this
daemon instead of spawning the usual stdio sidecar -- see "Workflow transport
selection" and "Chat transport selection" below. The two surfaces are
independent: the daemon's `CAPABILITIES` advertises both
`CHAT_TOOLS_CAPABILITY` and `WORKFLOW_TOOLS_CAPABILITY`, and each selector
picks `:persistent` once the daemon is healthy.

## Toggling

```ruby
Feature.find_by(slug: 'persistent_mcp_sidecar').update(enabled: false)
```

With the feature disabled, `PersistentMcpDaemon#start` raises immediately
and refuses to open a listener.

## Starting the daemon

```
bin/syrus-mcp-daemon
```

This boots Rails once (same boot path as `bin/jobs`), then starts a
[Puma::Server](https://github.com/puma/puma) bound to
`SYRUS_PERSISTENT_MCP_HOST` (default `127.0.0.1`, loopback-only) and
`SYRUS_PERSISTENT_MCP_PORT` (default `4805`). Worker processes lazy-start
the daemon the first time a selector needs it; set
`SYRUS_MCP_DAEMON_AUTO_START=0` to require an explicit `bin/syrus-mcp-daemon`
process instead. `SIGTERM`/`SIGINT` stop the explicit daemon process
gracefully.

## Surface

Two paths are served, both local-only:

- `GET /healthz` — proves the daemon booted, built an `MCP::Server` in
  memory, enumerated its tools, and round-tripped the MCP protocol's
  standard no-op `ping` method. Returns `200` with
  `{"status": "ok", "identity": {...}, "tools": ["daemon_ping"], "ping_ok": true}`
  on success, `503` otherwise.
- `/mcp` — the real MCP transport
  (`MCP::Server::Transports::StreamableHTTPTransport`, stateless mode),
  mountable by any MCP-speaking client. It exposes the known chat MCP tool
  surface, the workflow tool surface, and two proof-of-pipe tools:
  `daemon_ping` (`PersistentMcpDaemon::PingTool`), a no-op call that echoes
  the daemon's identity back, and `daemon_invocation_context`
  (`PersistentMcpDaemon::InvocationContextTool`), which resolves whatever
  signed context (see below) the caller attached to the request and echoes
  back what it reconstructed. The transport also independently enforces
  DNS-rebinding/loopback host protections per the MCP spec.

## Worker-local identity

`PersistentMcpDaemon#identity` returns `{worker_id, hostname, role, version,
pid}`. `worker_id` reuses `WorkerStorageIdentity`'s existing stable
per-data-root UUID (the same id `resume-<key>` queue routing already relies
on) rather than minting a second identity file — it survives daemon restarts
on the same worker volume. `pid` distinguishes the current process instance
across restarts.

## Per-invocation context (`McpInvocationContext`)

Stdio sidecars get a fresh subprocess per run or chat turn, so
per-invocation identifiers (`--run-id`, `SYRUS_CHAT_SESSION_ID`,
`SYRUS_CHAT_SCOPED_EVENT_ID`, ...) are safe as ENV/argv because nothing else
shares that process. The persistent daemon is a single process meant to
serve many concurrent runs/chats, so it cannot reuse that pattern — ENV and
any daemon-wide "current run"/"current chat" attribute would leak across
concurrent dispatches.

Generated MCP configs are agent-visible. Persistent transport keeps stdio-only
workflow and chat CLIs on `bin/syrus-mcp-proxy`, whose env carries only the
daemon URL plus a short-lived invocation token. The legacy direct
`bin/syrus-mcp-sidecar` fallback is different: it boots Rails as a child
process, so it receives the worker boot env needed for MySQL, Active Record
encryption, and S3-backed production boots. Shared service bearer tokens that
are not needed for Rails boot stay out of that direct-sidecar env. Chat has no
safe direct Rails stdio fallback under an agent-visible scrubbed environment;
when persistent chat transport is not selected, the generated chat MCP entries
point at a secret-free unavailable responder that reports that the persistent
daemon is required instead of attempting to boot Rails.

For agent CLIs that only support stdio MCP, the configured command is
`bin/syrus-mcp-proxy` when persistent transport is selected. The proxy does not
boot Rails and receives only the daemon URL plus a short-lived signed invocation
token. Rails/database/storage secrets stay in the worker-owned persistent
daemon process.

`McpInvocationContext` is a short-lived signed context envelope instead:
`.issue_for_run` / `.issue_for_chat` mint a token (via
`Rails.application.message_verifier(:mcp_invocation)`) carrying only the
minimum needed to dispatch a tool call — surface, run/chat/message ids,
tier, provider, the issuing `worker_id`, and an expiry (5 minutes by
default). `.resolve(token, worker_id:)` verifies the token is unexpired and
was minted for the dispatching worker, then reconstructs the same
`McpToolContext` stdio mode builds (`McpToolContext.from_run` /
`.from_chat_session`) — so tool availability (`McpToolPolicy`) stays
equivalent between the two dispatch modes. `.resolve` raises (and logs) a
specific `McpInvocationContext::InvalidContext` subclass for every rejection
reason: `Malformed` (blank/garbage/tampered token), `Expired`, `WrongWorker`
(minted for a different daemon instance), or `Unauthorized` (the referenced
run/chat no longer exists, or the token's claims no longer match it).

A caller passes the token through the MCP request's standard `_meta` field,
under `PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY`
(`:syrus_invocation_context`) — the MCP gem merges `_meta` into the shared
`server_context` per request, so each tool call resolves its own context
independently with no shared mutable state on the daemon.
`PersistentMcpDaemon::InvocationContextTool` (`daemon_invocation_context`)
proves this reconstruction over the real transport; it carries no other
capability.

## Workflow transport selection (`WorkflowMcpTransportSelector`)

Every agentic workflow step (`implement`, `respond`, `summarize`, ...) asks
`WorkflowMcpTransportSelector.select` how to configure its agent's MCP
transport before invoking. The decision is a `transport` (`:persistent` or
`:stdio`) plus a `reason` string for every non-persistent outcome:

- `feature_disabled` — the feature flag is off. The selector isn't even
  called in this case (`AgentProviders::Base#mcp_transport_decision` returns
  `nil`), so a disabled feature adds zero new log lines or network calls;
  behavior is byte-identical to before this selector existed.
- `daemon_unreachable: ...` — the feature is on but the daemon isn't
  listening (connection refused/timed out) at `PersistentMcpDaemon.host`:
  `PersistentMcpDaemon.port` on this worker.
- `daemon_unhealthy: ...` — the daemon answered `/healthz` but with a
  non-2xx status, `"status" != "ok"`, or an unparseable body.
- `daemon_incompatible: ...` — the daemon is healthy but its `/healthz`
  `capabilities` array doesn't include `PersistentMcpDaemon::WORKFLOW_TOOLS_CAPABILITY`
  (`"workflow_tools"`).
- `nil` (persistent, no fallback) — feature on, daemon healthy, compatible,
  and transport wiring exists. `AgentProviders::Claude` builds an
  `http`-type `mcpServers` entry pointing at `PersistentMcpDaemon::MCP_PATH`.
  Stdio-only workflow providers build a `stdio` entry for
  `bin/syrus-mcp-proxy`, which forwards JSON-RPC to that same daemon URL.

**Diagnostics**: every non-`nil` decision is recorded on `Step#details["mcp_transport"]`
(already serialized by `Admin::JobStateSerializer`, so it shows up in existing
run/job diagnostics with no extra plumbing) and as a `[mcp_transport]` JobLog
system line in the run transcript.

**Header-based context, not `_meta`**: `claude`/`codex` build their own
JSON-RPC bodies, so there's no config surface to make either CLI attach a
custom `_meta` key to a tool call. Instead, the persistent config's `headers`
map carries the signed `McpInvocationContext` token
(`PersistentMcpDaemon::INVOCATION_CONTEXT_HEADER`, a
`McpInvocationContext.issue_for_run` token scoped to the daemon's own
`worker_id`), and `PersistentMcpDaemon#inject_invocation_context` bridges
that header into the JSON-RPC request's `params._meta` before dispatch, so
tools keep reading `server_context[:_meta]` the same way regardless of how
the token arrived.

## Chat transport selection (`ChatMcpTransportSelector`)

Chat is a second, independent milestone on top of the same daemon.
Every `ChatTurnJob` turn asks `ChatMcpTransportSelector.select` the same
question `WorkflowMcpTransportSelector` answers for workflow steps, gated on
a different capability (`PersistentMcpDaemon::CHAT_TOOLS_CAPABILITY`,
`"chat_tools"`) so enabling chat routing doesn't imply workflow routing is
safe, or vice versa — `PersistentMcpDaemon::CAPABILITIES` advertises both
surfaces. Reasons mirror the workflow selector's (`feature_disabled`,
`daemon_unreachable: ...`, `daemon_unhealthy: ...`,
`daemon_incompatible: ...`), with no provider-specific downgrade: chat
providers that support HTTP MCP directly get HTTP entries, and stdio-only chat
providers get `bin/syrus-mcp-proxy` entries for the same daemon. For a
persistent decision (`reason: nil`), `ChatTurnJob` builds entries for BOTH the
essential and deferred config keys (`"syrus-chat-sidecar"` /
`"syrus-chat-deferred-sidecar"`, same names as stdio mode, same reason as
workflow: resumed sessions derive MCP tool prefixes from the config key). Each
entry carries its own `McpInvocationContext.issue_for_chat` token so the daemon
can tell which tier a given call belongs to.

**Diagnostics**: every non-`nil` decision is recorded on
`ChatSession#artifact("mcp_transport")` (via `ChatSession#set_artifact!`, the
same read/write convention `SubmitArtifactTool` uses for `typed_artifacts`)
and as a Rails log line — `warn`-level specifically for a stdio fallback so
"feature enabled, daemon failed" is greppable via the `read_syrus_logs` MCP
tool, not just via manual inspection of a specific chat's artifacts.

**Tool dispatch (`PersistentMcpDaemon::ChatToolDispatch`,
`PersistentMcpDaemon::ChatContextResolver`,
`PersistentMcpDaemon::WorkflowToolDispatch`,
`PersistentMcpDaemon::WorkflowContextResolver`)**: the daemon registers the
full known chat and workflow tool surfaces once at boot, each tool wrapped so
a call resolves its own per-invocation context. Chat dispatch rebuilds the
same `{chat_session:, current_message:, evaluator:, scoped_event_id:,
evaluator_session_id:}` shape `Mcp::Sidecar.chat_context` builds for stdio
mode, and workflow dispatch rebuilds the same run-scoped
`McpToolContext.from_run` used by `Mcp::Sidecar.workflow_context`. Each call
computes the context-scoped allowed tool set before invoking the underlying
tool. A call to a tool outside that set is denied (`not_authorized`)
regardless of what the daemon's static tool list contains, so tiering,
admin-only gating, feature flags, plugin state, and per-step tool policy stay
enforced at dispatch time.

**Usage logging is authoritative at this boundary.** `ChatToolDispatch` wraps
every call (success, `not_authorized`, and an invalid/expired/wrong-worker
`McpInvocationContext`) with `McpToolUsageRecorder.record_dispatch`, tagging
the resulting `mcp_tool_usages` row `sidecar_mode: "persistent"` plus the
dispatching daemon's `worker_id`. `ChatTurnJob` skips its own
transcript-derived recording for any turn whose transport decision was
`:persistent` (`ChatTurnJob#record_transcript_mcp_usage?`), so a persistent-
mode call is recorded exactly once, at the daemon, not twice. See
`mcp_tool_usage.md`'s "Sidecar mode" section for the full comparison between
this path and stdio's transcript-derived recording, including how a
before-dispatch rejection ends up as a `status: "failed"` row with no
`chat_session` when the invocation context couldn't even be resolved.

**Known gap: `tools/list` advertises a superset.** The underlying `mcp` gem
builds a server's tool list once at `MCP::Server.new(tools:)` time with no
per-request hook, so unlike stdio mode's genuinely tier-scoped process, the
persistent daemon's `tools/list` response is the same full known tool surface
for every chat tier and workflow step. This does not weaken the security
boundary (enforced per call by the dispatch wrappers, above) but does mean an
MCP client may discover tools that a specific invocation cannot call.
Narrowing `tools/list` itself would need either patching the vendored `mcp`
gem or splitting the daemon into multiple `MCP::Server` instances server-side;
out of scope for this milestone.

**Evaluator tier stays stdio-only.** `ChatEventEvaluator::ProviderRunner` (the
disposable scoped-event evaluator, distinct from `ChatTurnJob`) is not
wired to `ChatMcpTransportSelector` and always spawns
`bin/syrus-chat-sidecar --tier evaluator`; its tool set
(`McpToolPolicy#chat_evaluator_tools`) includes at least one tool
(`SubmitScopedEventDecisionTool`) that isn't registered in `McpToolRegistry`
at all, so it isn't part of the daemon's registered chat tool surface either.

## What this is not (yet)

- The chat evaluator tier (see above) is out of scope for this milestone.
