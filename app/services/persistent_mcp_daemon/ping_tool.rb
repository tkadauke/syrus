require "mcp"

# The only tool exposed by the persistent MCP sidecar daemon skeleton. It
# exists purely to prove request dispatch works end to end (build server,
# enumerate tools, accept and answer a no-op call) — it is intentionally not
# part of SyrusMcp::CoreToolSet or McpToolRegistry, and no workflow or chat
# agent capability is wired to it yet.
class PersistentMcpDaemon::PingTool < MCP::Tool
  tool_name "daemon_ping"

  description "No-op readiness check for the persistent MCP sidecar daemon skeleton. Confirms the daemon can accept and answer a tool call; carries no other capability."

  input_schema(properties: {})

  class << self
    def call(server_context: {})
      identity = server_context[:identity] || {}
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(ok: true, identity: identity) } ])
    end
  end
end
