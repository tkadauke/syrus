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
already ships two transports for the identical tool surface: stdio (the
default path) and streamable HTTP, entered with `--port <port> [--host
0.0.0.0]`, served at `<endpoint>/mcp`. Syrus's `mcp` gem ships a full client
for both -- `MCP::Client::Stdio` and `MCP::Client::HTTP` -- behind the same
transport-agnostic `MCP::Client` (`#connect`, `#call_tool`, `#close`). So the
chosen boundary for the container-backed Browser Plugin Runtime service
(below) is: run `playwright-mcp --headless --isolated --block-service-workers
--port <port> --host 0.0.0.0` as the service's process (mirroring Git
Mirror's `PluginRuntime::Service` container contract), and have `Session`
connect to it with `MCP::Client::HTTP` instead of spawning a local
subprocess.

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

- **`.spawn_stdio(session_key, command:, args:, env:)`** -- the fallback
  path: spawns `playwright-mcp` as a per-owner stdio subprocess baked into
  the worker image.
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

## The container-backed service

`plugins/browser/container/` builds the image `SyrusBrowser::RuntimeService`
contributes through `"plugin_runtime:service"`. It runs `@playwright/mcp`
exactly as documented above -- `--headless --isolated --block-service-workers
--no-sandbox --allowed-hosts '*'` -- bound to a loopback-only address inside
the container, plus a small Go bridge (`internal/bridge`) that owns the
service's actual exposed port (8080).

The bridge exists for one reason: `@playwright/mcp`'s own HTTP transport
answers every plain GET with a 4xx (it only understands a POST that starts an
MCP session, or a GET carrying an already-established `mcp-session-id`
header), so nothing at its own port can serve as the HTTP health check the
`PluginRuntime::Service` contract expects (`healthcheck: { path: "/healthz"
}`, probed with a plain GET by both `PluginRuntime::ManagedDriver` and
`PluginRuntime::ExternalDriver`). The bridge answers `GET /healthz` itself --
from a live TCP dial to the `@playwright/mcp` child process, not a cached
flag -- and reverse-proxies everything else (the real MCP traffic, including
the DELETE that ends a streamable HTTP session) straight through.
`--no-sandbox` mirrors `@playwright/mcp`'s own documented container recipe:
Chromium's setuid sandbox helper needs privileges this service intentionally
does not have, matching the existing Plugin Runtime manager policy of no
extra container privileges. `--allowed-hosts '*'` turns off
`@playwright/mcp`'s own Host-header check, which would otherwise reject
traffic arriving with the service's Compose DNS name in the `Host` header
instead of the loopback address it bound to -- the bridge's exposed port is
the actual network boundary, not that check.

No volumes: a browser session's state lives only as long as its MCP
connection (`--isolated`) and leaves nothing behind when it closes. No env:
unlike Git Mirror this service holds no secret to share with Syrus, and
`Session.spawn_service` does not send it any request headers today, so the
service accepts every request that reaches its exposed port -- the project
network Plugin Runtime places it on, never published to the host, is what
keeps that reachable only from Syrus's own web/worker containers.

Images are published by `bin/publish-plugin-images`, the same convention
`plugin_runtime` and `git_mirror` use (`plugins/*/container/Dockerfile` ->
`ghcr.io/tkadauke/syrus-plugin-browser`), tagged to match the Syrus release
that runs them (`SyrusBrowser::Configuration.image`).

**Browser only `optionally_depends_on` Plugin Runtime, not `depends_on`.**
Unlike Git Mirror -- which is off by default and exists purely as a Plugin
Runtime accelerator -- Browser is on by default and must keep offering all of
its tools (workflow `visual_review`, Coding Mode's browser RuntimeSession)
purely through the bundled stdio subprocess when Plugin Runtime is disabled,
which it is out of the box on every fresh install (`plugin_runtime`'s own
`default_enabled` is `false`). A hard `depends_on` would mark the whole
Browser plugin `:degraded` and withhold every one of its providers --
not just the service -- the moment nobody has separately opted into Plugin
Runtime, which is the common case. `SyrusBrowser::Configuration.endpoint`
resolves `PluginRuntime::Services` by name
(`"PluginRuntime::Services".safe_constantize`) rather than through a bare
constant reference for the same reason one level down: it must return `nil`
gracefully even if the `plugin_runtime` plugin were physically removed from
the tree, not just logically disabled.

## Safety model

Browser navigation is scoped to loopback preview URLs regardless of
transport (`LoopbackGuard`, enforced by `NavigateTool` before any tool call
reaches `Session`). The service-backed path does not change that: the guard
runs in Syrus, not in `@playwright/mcp`, so it applies identically to a
spawned subprocess or a shared service connection.

## Operations

**Inspecting and restarting the service** goes through the generic Plugin
Services admin page (`/admin/plugin_services`, documented in full in
`plugin_runtime.md`), the same as every other container-backed plugin. For
`browser` specifically:

- **Status** shows `pending`/`pulling`/`starting`/`running`/`unhealthy`/
  `stopped`/`error`/`unavailable`/`unconfigured`, the container image, and
  the last health-check error, if any -- e.g. `GET /healthz: connection
  refused` when the `@playwright/mcp` child process has died or is still
  starting. That is always enough to tell "the service is down, Browser is
  falling back to per-Run subprocesses" from "the service is healthy" without
  needing to open a shell.
- **Logs** streams the bridge's and `@playwright/mcp`'s own stdout/stderr --
  process startup, the health-check dial, and any command-level errors. It
  never contains per-session browser traffic: the bridge
  (`internal/bridge`) is a plain reverse proxy with no request-logging
  middleware, so a navigated URL, a page snapshot, form values typed into a
  page, or a screenshot never appear in the container's logs, regardless of
  which owning Run or Coding Mode chat generated them. Logs are diagnostic
  about the service process, not an audit trail of what agents did with a
  browser -- that already lives on the owning Run/chat (submitted
  screenshots, tool call transcripts), not here.
- **Details** does not appear for `browser` even while it is `running`: the
  Details panel is opt-in per service
  (`PluginRuntime::Service#service_details`), and `SyrusBrowser::RuntimeService`
  deliberately implements no `service_details` because there is nothing safe
  and useful to summarize -- the service holds no state across sessions (see
  "No volumes" above), so there is no session list, page inventory, or
  history a details view could show. Absence of a Details action here is a
  guarantee, not an oversight: it structurally keeps live session content out
  of the admin page.
- **Stop/Start/Restart** behave exactly as documented for any managed
  service. Stopping it is safe at any time -- `Session.spawn` falls back to
  the bundled stdio subprocess automatically the next time a Run or chat
  opens a browser session, no operator action required beyond restarting the
  service when ready.

**Fallback is silent by design.** Nothing pages an operator when the service
degrades; `Session.spawn` just stops choosing it (`Configuration.endpoint`
reads `nil` the moment the health check stops passing) and every new session
goes back through the worker's bundled stdio subprocess. The service is an
accelerator, never a hard dependency -- see "The container-backed service"
above. Use the admin page's state/logs when you want to know *why* it went
away, not because anything stopped working.
