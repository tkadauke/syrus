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
  mountable by any MCP-speaking client. It currently exposes exactly one
  tool, `daemon_ping` (`PersistentMcpDaemon::PingTool`) — a no-op call that
  echoes the daemon's identity back. This is deliberate: the skeleton proves
  the transport and dispatch path work end to end without wiring any real
  workflow or chat tool capability to it. The transport also independently
  enforces DNS-rebinding/loopback host protections per the MCP spec.

## Worker-local identity

`PersistentMcpDaemon#identity` returns `{worker_id, hostname, role, version,
pid}`. `worker_id` reuses `WorkerStorageIdentity`'s existing stable
per-data-root UUID (the same id `resume-<key>` queue routing already relies
on) rather than minting a second identity file — it survives daemon restarts
on the same worker volume. `pid` distinguishes the current process instance
across restarts.

## What this is not (yet)

- No workflow or chat agent points its MCP transport at this daemon. Every
  agent invocation still spawns the existing per-run/per-session stdio
  sidecar exactly as before, whether or not this feature is enabled.
- No real tool dispatch, context isolation, or tool-usage logging beyond the
  no-op `daemon_ping` tool. Those are later EPIC-250 milestones.
