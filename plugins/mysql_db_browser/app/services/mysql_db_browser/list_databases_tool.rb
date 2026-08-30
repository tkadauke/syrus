require "mcp"

module MysqlDbBrowser
  class ListDatabasesTool < MCP::Tool
    tool_name "mysql_db_browser_list_databases"

    description "List databases (schemas) on an agentic-access-enabled MySQL DB Browser connection, " \
                "including the standard MySQL system schemas. Call mysql_db_browser_list_connections " \
                "first to find an enabled mysql_connection_id."

    input_schema(
      type: "object",
      required: [ "mysql_connection_id" ],
      properties: {
        mysql_connection_id: {
          type: "integer",
          description: "MysqlConnection id from mysql_db_browser_list_connections."
        }
      }
    )

    class << self
      def call(server_context:, mysql_connection_id: nil)
        Mcp::Tools.with_database_connection do
          connection = AgenticAccess.connection!(mysql_connection_id)
          payload = SchemaInspector.new(connection).databases
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload[:error].present?)
        end
      rescue AgenticAccess::ConnectionNotFound, AgenticAccess::AccessDisabled, SchemaInspector::Unavailable => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[MysqlDbBrowser::ListDatabasesTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
