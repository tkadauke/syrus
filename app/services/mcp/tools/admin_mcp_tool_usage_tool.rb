require "mcp"

module Mcp::Tools
  class AdminMcpToolUsageTool < MCP::Tool
    SURFACES = (McpToolUsage::SURFACES + [ "all" ]).freeze

    tool_name "admin_mcp_tool_usage"

    description "Read aggregate MCP tool usage stats. Admin-only; never returns raw tool inputs or results."

    input_schema(
      properties: {
        surface: {
          type: "string",
          description: "Usage surface to query: chat, workflow, or all. Defaults to chat."
        },
        window: {
          type: "string",
          description: "Relative lookback window such as 2h, 7d, or 4w. Clamped to the admin maximum."
        },
        since: {
          type: "string",
          description: "Relative lookback such as 24h, or an absolute timestamp for the window start."
        },
        start: {
          type: "string",
          description: "Absolute timestamp for the window start."
        },
        end: {
          type: "string",
          description: "Absolute timestamp for the window end."
        },
        tool_name: {
          type: "string",
          description: "Filter by normalized MCP tool name."
        },
        tool: {
          type: "string",
          description: "Alias for tool_name."
        },
        server_name: {
          type: "string",
          description: "Filter by MCP server name."
        },
        server: {
          type: "string",
          description: "Alias for server_name."
        },
        limit: {
          type: "integer",
          description: "Maximum rows for aggregate top/error lists. Capped by the admin payload."
        },
        recent_limit: {
          type: "integer",
          description: "Maximum recent-call metadata rows. Capped by the admin payload."
        }
      }
    )

    class << self
      def call(server_context:, surface: nil, window: nil, since: nil, start: nil, tool_name: nil, tool: nil, server_name: nil, server: nil, limit: nil, recent_limit: nil, **kwargs)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        surface = normalized_surface(surface)
        return Mcp::Tools.invalid("surface must be one of #{SURFACES.join(', ')}") unless surface

        Mcp::Tools.success(::Admin::McpToolUsagePayload.new(params: {
          surface: surface == "all" ? nil : surface,
          window: window,
          since: since,
          start: start,
          end: kwargs[:end],
          tool_name: tool_name,
          tool: tool,
          server_name: server_name,
          server: server,
          limit: limit,
          recent_limit: recent_limit
        }.compact).as_json)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def normalized_surface(surface)
        value = surface.to_s.strip.presence || "chat"
        return value if SURFACES.include?(value)
      end
    end
  end
end
