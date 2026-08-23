require "mcp"

module AdminMysql
  class KillQueryTool < MCP::Tool
    tool_name "admin_mysql_kill_query"

    description "Kill the currently executing query for a MySQL thread id using KILL QUERY. " \
                "This does not close the connection."

    input_schema(
      type: "object",
      required: [ "thread_id" ],
      properties: {
        thread_id: {
          type: "integer",
          minimum: 1,
          description: "MySQL PROCESSLIST.ID to interrupt."
        }
      }
    )

    class << self
      def call(server_context:, thread_id: nil)
        payload = Inspector.new.kill_query(thread_id)
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload.dig(:error).present?)
      rescue Inspector::Unavailable, ArgumentError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[AdminMysql::KillQueryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
