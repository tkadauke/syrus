require "mcp"

module MysqlDbBrowser
  class ExecuteQueryTool < MCP::Tool
    tool_name "mysql_db_browser_execute_query"

    description "Run a SQL statement against an agentic-access-enabled MySQL DB Browser connection. " \
                "Read-only (SELECT/WITH) by default - rejected unless the connection has explicitly " \
                "opted into writes. Every attempt, successful or not, is audit-logged."

    input_schema(
      type: "object",
      required: [ "mysql_connection_id", "sql" ],
      properties: {
        mysql_connection_id: {
          type: "integer",
          description: "MysqlConnection id, from the DB Browser connections list."
        },
        sql: {
          type: "string",
          description: "SQL statement to run."
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: QueryExecutor::MAX_LIMIT,
          description: "Maximum rows to return for a SELECT (default #{QueryExecutor::DEFAULT_LIMIT})."
        }
      }
    )

    class << self
      def call(server_context:, mysql_connection_id: nil, sql: nil, limit: nil)
        Mcp::Tools.with_database_connection do
          connection = AgenticAccess.connection!(mysql_connection_id)
          user = MysqlDbBrowser.user_from_server_context(server_context)
          payload = QueryExecutor.new(connection).execute(sql, user: user, limit: limit || QueryExecutor::DEFAULT_LIMIT)
          MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload[:error].present?)
        end
      rescue AgenticAccess::ConnectionNotFound, AgenticAccess::AccessDisabled => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue QueryExecutor::BlankStatement, QueryExecutor::WriteNotAllowed, QueryExecutor::Unavailable => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[MysqlDbBrowser::ExecuteQueryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
