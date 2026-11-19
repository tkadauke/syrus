# MCP bridge

`/mcp/bridge` serves the chat MCP tool surface to external MCP clients over
streamable HTTP. User-facing behavior is in `config/syrus_docs/mcp_bridge.md`;
this page covers how it is wired.

## Pieces

- `McpBridgeToken` -- a revocable credential, stored as a SHA-256 digest with
  a short display prefix. It is never the user's `api_token`, and
  `Api::BaseController` does not accept it. Each token owns one bridge chat
  (`ChatSession` with `origin_platform: "mcp_bridge"`), created lazily by
  `#bridge_chat!` and recreated if the operator deleted it.
- `McpBridge::Endpoint` -- a Rack endpoint mounted in `config/routes.rb`. Per
  HTTP request it authenticates the bearer token, builds an `MCP::Server`
  whose tools are `Mcp::Sidecar.chat_tools(chat, tier: :all)` and whose
  server context is `Mcp::Sidecar.chat_context(chat, ...)`, and answers through
  a stateless `StreamableHTTPTransport` with JSON responses (the gem's
  Rails-controller pattern). Nothing outlives the request, so revocation and
  permission changes apply to the next call.
- `Api::V1::App::McpBridgeTokensController` and the Account settings panel
  issue, list and revoke tokens.

## Invariants

- **One policy.** The bridge never chooses tools or decides permissions
  itself. `Mcp::Sidecar.chat_tools` is the single source of truth for the tool
  list, and its `authorize_tool` wrapper is the gate, exactly as for the stdio
  sidecar and the persistent daemon. Essentials stay non-deniable; gated tools
  create cards in the bridge chat.
- **No Syrus agent turns in a bridge chat.** `ChatTurnJob` returns early for
  `ChatSession#mcp_bridge?`. Pending-action outcomes still post their system
  message there (the client reads them with `list_pending_actions`), but the
  wake they enqueue is a no-op.
- **Usage is recorded at the boundary.** The endpoint reads the JSON-RPC
  `tools/call` envelope and records `McpToolUsage` with
  `sidecar_mode: "bridge"`, including calls the gate refused.
- **Host checks.** The transport's DNS-rebinding guard is given the request
  host: the endpoint is authorized by a bearer token rather than ambient
  browser credentials, and Rails host authorization has already admitted the
  `Host` header. Repeated bad tokens are rate-limited per IP like the REST API.
