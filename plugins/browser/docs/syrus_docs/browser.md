# Browser

Browser gives workflow agents (`visual_review`) and Coding Mode chats
(RuntimeSessions) a constrained, headless Playwright browser: navigate,
click, fill, hover, drag/drop, upload, evaluate JS, snapshot, screenshot,
resize, wait, and close. Navigation is hard-restricted to loopback URLs (see
`LoopbackGuard`) -- the browser can only drive a session's own in-step
preview, never an arbitrary network destination. On by default.

## Service boundary

`@playwright/mcp` is Microsoft's own MCP server for Playwright, and it is
the entire surface Browser proxies -- `McpToolSet`'s granular tools
(`browser_navigate`, `browser_click`, ...) forward almost 1:1 to it through
`BrowserTool.call` -> `SessionRegistry.fetch` -> `Session#call_tool`. That
one choke point is also the whole of Browser's service boundary: every
owning session (a workflow Run, or a Coding Mode chat's RuntimeSession) gets
its own `Session`, wrapping one `MCP::Client` connection reused across every
tool call so a multi-step flow sees the same page Playwright left it in
(`SessionRegistry`, keyed by `SessionContext#session_key`).

**Protocol: streamable HTTP MCP, spoken by the same binary.** `@playwright/mcp`
already ships two transports for the identical tool surface: stdio (today's
path) and streamable HTTP, entered with `--port <port> [--host 0.0.0.0]`,
served at `<endpoint>/mcp`. Syrus's `mcp` gem ships a full client for both --
`MCP::Client::Stdio` and `MCP::Client::HTTP` -- behind the same
transport-agnostic `MCP::Client` (`#connect`, `#call_tool`, `#close`). So the
chosen boundary for a future container-backed Browser Plugin Runtime service
is: run `playwright-mcp --headless --isolated --block-service-workers --port
<port> --host 0.0.0.0` as the service's process (mirroring Git Mirror's
`PluginRuntime::Service` container contract), and have `Session` connect to
it with `MCP::Client::HTTP` instead of spawning a local subprocess.

This was chosen over a bespoke Syrus-specific HTTP API or another bridge
protocol because it needs no translation layer at all: the exact same
`@playwright/mcp` tool schema reaches the agent either way, `MCP::Client`
does not care which transport it holds, and `BrowserTool` and every
`browser_*` tool class stay untouched -- they only ever call
`session.call_tool(name:, arguments:)`. The streamable HTTP transport's own
session semantics (`Mcp-Session-Id`) are also exactly what "session reuse per
owner, isolated browser state" needs: each owning `Session` opens its own MCP
session against the shared service and gets its own isolated browser
context, the same guarantee `--isolated` gives the stdio path today, without
Syrus building any per-owner multiplexing of its own.

## Client shape

`SyrusBrowser::Session` exposes three class-level entry points, all
returning a `Session` wrapping one `MCP::Client`:

- **`.spawn_stdio(session_key, command:, args:, env:)`** -- today's
  behavior: spawns `playwright-mcp` as a per-owner stdio subprocess baked
  into the worker image.
- **`.spawn_service(session_key, endpoint:, headers: {})`** -- connects to
  a Browser Plugin Runtime service at `endpoint` over streamable HTTP MCP
  (`MCP::Client::HTTP`, pointed at `<endpoint>/mcp`).
- **`.spawn(session_key, ...)`** -- the fallback-selecting entry point
  `SessionRegistry`'s default factory actually calls. Reads
  `SyrusBrowser::Configuration.endpoint`
  (`PluginRuntime::Services.endpoint_for("browser")`, which never makes a
  network call -- it reads the last Plugin Runtime reconcile) and picks
  `.spawn_service` when it answers an address, `.spawn_stdio` otherwise.

`#call_tool`, `#close`, and the once-per-session "clear browser state on
first navigate" behavior live on `Session` itself and need no
transport-specific branching: `MCP::Client#call_tool`/`#connect` and
`MCP::Client::HTTP#close` (a session-terminating DELETE) already implement
the same contract `MCP::Client::Stdio` does.

## What is not built yet

This plugin does not yet contribute a `"plugin_runtime:service"` provider
(no `RuntimeService`, no `plugins/browser/container/`, no published image),
so `SyrusBrowser::Configuration.endpoint` answers nil in every deployment
today and `Session.spawn` always falls back to the stdio subprocess --
current behavior is unchanged. Building the actual container-backed service
is later work (`optionally_depends_on ["plugin_runtime"]` on this plugin's
manifest documents the coupling without requiring Plugin Runtime to be
enabled): once a service is registered and passes its health check,
`Session.spawn` starts using it automatically, and the stdio path stays
available as the fallback for as long as it takes to reach full parity, or
for a deployment that has no Plugin Runtime service configured at all.

## Safety model

Browser navigation is scoped to loopback preview URLs regardless of
transport (`LoopbackGuard`, enforced by `NavigateTool` before any tool call
reaches `Session`). A future service-backed path does not change that: the
guard runs in Syrus, not in `@playwright/mcp`, so it applies identically to
a spawned subprocess or a shared service connection.
