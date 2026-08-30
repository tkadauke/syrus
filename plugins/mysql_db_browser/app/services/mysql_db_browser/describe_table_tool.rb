require "mcp"

module MysqlDbBrowser
  class DescribeTableTool < MCP::Tool
    tool_name "mysql_db_browser_describe_table"

    description "Describe a table (info, columns, indexes, foreign keys) on an agentic-access-enabled " \
                "MySQL DB Browser connection. Call mysql_db_browser_list_connections first to find " \
                "an enabled mysql_connection_id."

    input_schema(
      type: "object",
      required: [ "mysql_connection_id", "database", "table" ],
      properties: {
        mysql_connection_id: {
          type: "integer",
          description: "MysqlConnection id from mysql_db_browser_list_connections."
        },
        database: {
          type: "string",
          description: "Database (schema) name."
        },
        table: {
          type: "string",
          description: "Table name."
        }
      }
    )

    class << self
      def call(server_context:, mysql_connection_id: nil, database: nil, table: nil)
        Mcp::Tools.with_database_connection do
          connection = AgenticAccess.connection!(mysql_connection_id)
          payload = SchemaInspector.new(connection).table(database, table)
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
        end
      rescue AgenticAccess::ConnectionNotFound, AgenticAccess::AccessDisabled, SchemaInspector::Unavailable, SchemaInspector::NotFound => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[MysqlDbBrowser::DescribeTableTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
