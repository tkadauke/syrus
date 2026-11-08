# Chat and sidecars

## Durable chat

Chat sessions, messages, tool calls, attachments, goals, provider sessions,
and spawned processes are durable Rails records. Provider adapters render the
conversation and invoke the selected model, while Rails retains authorization,
tool policy, and persistence. Chat workspace operations are routed to the
worker that owns the workspace.

The main entry points are `app/models/chat_session.rb`,
`app/services/chat/`, `app/services/chat_workspace.rb`, and the chat API under
`app/controllers/api/v1/app/`. Provider sessions preserve resumable provider
state but do not replace the Syrus conversation record.

## MCP sidecars

Workflow Runs and chats use separate scoped sidecars. Registries decide which
tools are advertised; handlers call authenticated Rails endpoints or local
workspace services. The sidecar process owns protocol translation, while Rails
owns business authorization and durable mutations. See
`app/services/mcp_tool_registry.rb`, `app/services/mcp/`,
`app/services/syrus_mcp/`, and the `bin/syrus-mcp-*` entry points.

New chat-facing tools need an explicit renderer decision: a core or
plugin-owned tool card, or an explicit generic, hidden, or deferred status in
`Admin::McpToolCardCoverage`. Collapsed shared tool-card headers retain their
single-line geometry; tool-specific cards may not override it.

## Previews and external chat

Preview processes are worker-local children. `PreviewProxyMiddleware` and the
preview services route browser traffic to the owning worker and enforce the
allowed path and host boundary. Files are served through the same ownership
model rather than assuming a shared web/worker filesystem.

External platform adapters map a `PlatformIdentity` to a Syrus user and route
messages into the same chat domain. Platform-specific code and docs remain in
the owning plugin. Core does not duplicate the adapter's operational guide.
