require "mcp"

module AdminMysql
  class StatusTool < MCP::Tool
    tool_name "admin_mysql_status"

    description "Read live MySQL status, process list, connection information, slow-log availability, " \
                "and statement digests for this Syrus instance."

    input_schema(
      type: "object",
      properties: {
        limit: {
          type: "integer",
          minimum: 1,
          maximum: Inspector::MAX_LIMIT,
          description: "Maximum number of process list rows to return."
        }
      }
    )

    class << self
      def call(server_context:, limit: nil)
        payload = Inspector.new.snapshot(limit: limit || Inspector::DEFAULT_LIMIT)
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload.dig(:error).present?)
      rescue Inspector::Unavailable, ArgumentError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[AdminMysql::StatusTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
