# Persistent MCP sidecar (skeleton)

Workflow and chat agents normally talk to Syrus over a stdio MCP server that
is spawned fresh for every run or chat turn (`Mcp::Sidecar`, see
`bin/syrus-mcp-sidecar` / `bin/syrus-chat-sidecar`). Booting one of those
sidecars boots Rails from scratch each time, which is expensive and can fail
under load.

`persistent_mcp_sidecar` is a labs feature (default off) gating an
experimental, worker-local **daemon skeleton** that boots Rails once and
stays up, instead of once per run. `WorkflowMcpTransportSelector` decides,
per workflow agent invocation, whether to route that run's MCP traffic to
this daemon instead of spawning the usual stdio sidecar -- see "Workflow
transport selection" below. Enabling the feature alone does not change
behavior: the daemon's tool surface is still a skeleton (`CAPABILITIES` is
empty), so the selector always falls back to stdio in production until a
later EPIC-250 milestone wires the real workflow tool set onto the daemon.

## Enabling

```ruby
Feature.find_by(slug: 'persistent_mcp_sidecar').update(enabled: true)
```

With the feature disabled (the default), `PersistentMcpDaemon#start` raises
immediately and refuses to open a listener — the safest way to guarantee the
daemon never runs unexpectedly in an environment that hasn't opted in.

## Starting the daemon

```
bin/syrus-mcp-daemon
```

This boots Rails once (same boot path as `bin/jobs`), then starts a
[Puma::Server](https://github.com/puma/puma) bound to
`SYRUS_PERSISTENT_MCP_HOST` (default `127.0.0.1`, loopback-only) and
`SYRUS_PERSISTENT_MCP_PORT` (default `4805`). It is not started
automatically by any existing process (`bin/dev`, worker pods, etc.) — an
operator or process supervisor starts it explicitly in a controlled
environment. `SIGTERM`/`SIGINT` stop the Puma listener gracefully.

## Surface

Two paths are served, both local-only:

- `GET /healthz` — proves the daemon booted, built an `MCP::Server` in
  memory, enumerated its tools, and round-tripped the MCP protocol's
  standard no-op `ping` method. Returns `200` with
  `{"status": "ok", "identity": {...}, "tools": ["daemon_ping"], "ping_ok": true}`
  on success, `503` otherwise.
- `/mcp` — the real MCP transport
  (`MCP::Server::Transports::StreamableHTTPTransport`, stateless mode),
  mountable by any MCP-speaking client. It exposes two tools:
  `daemon_ping` (`PersistentMcpDaemon::PingTool`), a no-op call that echoes
  the daemon's identity back, and `daemon_invocation_context`
  (`PersistentMcpDaemon::InvocationContextTool`), which resolves whatever
  signed context (see below) the caller attached to the request and echoes
  back what it reconstructed. Neither wires any real workflow or chat tool
  capability to the daemon yet. The transport also independently enforces
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
  (`"workflow_tools"`). This is the outcome in production today, since
  `PersistentMcpDaemon::CAPABILITIES` is still empty (see above).
- `provider_unsupported: ...` — Codex-only. Codex's MCP config
  (`config.toml`) has no verified remote/HTTP transport wiring in this
  codebase, so `AgentProviders::Codex` downgrades any `:persistent` decision
  to `:stdio` with this reason before it ever builds a config, regardless of
  daemon health/compatibility.
- `nil` (persistent, no fallback) — feature on, daemon healthy, compatible,
  and (Claude only) transport wiring exists. `AgentProviders::Claude` then
  builds an `http`-type `mcpServers` entry pointing at
  `PersistentMcpDaemon::MCP_PATH` instead of the usual `stdio` entry, keeping
  the same `"syrus-mcp-sidecar"` config key either way (required-tool
  enforcement in `ClaudeInvocation#required_mcp_tools_update` looks up that
  exact name in claude's init event, independent of transport).

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

## What this is not (yet)

- No real tool dispatch beyond the `daemon_ping` / `daemon_invocation_context`
  proof-of-pipe tools, and no tool-usage logging. Wiring the real workflow
  tool set (`Mcp::Tools`) onto this daemon so `WorkflowMcpTransportSelector`
  can actually pick `:persistent` in production, and doing the same for chat
  agents, are later EPIC-250 milestones.
- Codex has no persistent transport wiring (see `provider_unsupported`
  above) — only `AgentProviders::Claude` builds an `http`-type MCP config
  when the selector picks `:persistent`.
