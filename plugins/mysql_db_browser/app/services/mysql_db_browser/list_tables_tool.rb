require "mcp"

module MysqlDbBrowser
  class ListTablesTool < MCP::Tool
    tool_name "mysql_db_browser_list_tables"

    description "List tables in a database on an agentic-access-enabled MySQL DB Browser connection. " \
                "Call mysql_db_browser_list_connections first to find an enabled mysql_connection_id."

    input_schema(
      type: "object",
      required: [ "mysql_connection_id", "database" ],
      properties: {
        mysql_connection_id: {
          type: "integer",
          description: "MysqlConnection id from mysql_db_browser_list_connections."
        },
        database: {
          type: "string",
          description: "Database (schema) name."
        }
      }
    )

    class << self
      def call(server_context:, mysql_connection_id: nil, database: nil)
        Mcp::Tools.with_database_connection do
          connection = AgenticAccess.connection!(mysql_connection_id)
          payload = SchemaInspector.new(connection).tables(database)
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload[:error].present?)
        end
      rescue AgenticAccess::ConnectionNotFound, AgenticAccess::AccessDisabled, SchemaInspector::Unavailable => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[MysqlDbBrowser::ListTablesTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
