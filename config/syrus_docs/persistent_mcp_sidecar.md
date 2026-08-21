# Persistent MCP sidecar (skeleton)

Workflow and chat agents normally talk to Syrus over a stdio MCP server that
is spawned fresh for every run or chat turn (`Mcp::Sidecar`, see
`bin/syrus-mcp-sidecar` / `bin/syrus-chat-sidecar`). Booting one of those
sidecars boots Rails from scratch each time, which is expensive and can fail
under load.

`persistent_mcp_sidecar` is a labs feature (default off) gating an
experimental, worker-local **daemon skeleton** that boots Rails once and
stays up, instead of once per run. This is EPIC-250's foundation step only:
the daemon exists and can prove it is healthy, but no workflow or chat agent
is configured to talk to it yet. Enabling the feature does not change any
existing agent's behavior.

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

## What this is not (yet)

- No workflow or chat agent points its MCP transport at this daemon. Every
  agent invocation still spawns the existing per-run/per-session stdio
  sidecar exactly as before, whether or not this feature is enabled — nothing
  issues `McpInvocationContext` tokens for a real dispatch yet.
- No real tool dispatch beyond the `daemon_ping` / `daemon_invocation_context`
  proof-of-pipe tools, and no tool-usage logging. Those are later EPIC-250
  milestones.
