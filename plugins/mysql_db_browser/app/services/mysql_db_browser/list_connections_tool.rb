require "mcp"

module MysqlDbBrowser
  class ListConnectionsTool < MCP::Tool
    tool_name "mysql_db_browser_list_connections"

    description "List configured MySQL DB Browser connections with safe metadata only. " \
                "Use this first to find mysql_connection_id values before listing databases, " \
                "listing tables, describing tables, or executing queries."

    input_schema(
      type: "object",
      properties: {}
    )

    class << self
      def call(server_context:)
        Mcp::Tools.with_database_connection do
          payload = {
            mysql_connections: AgenticAccess.safe_connection_metadata
          }
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
        end
      rescue StandardError => e
        Rails.logger.error("[MysqlDbBrowser::ListConnectionsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
