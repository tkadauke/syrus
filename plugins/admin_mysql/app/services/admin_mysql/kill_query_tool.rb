require "mcp"

module AdminMysql
  class KillQueryTool < MCP::Tool
    extend Mcp::Tools::AdminPendingActionToolSupport

    tool_name "admin_mysql_kill_query"

    description "Request interruption of the currently executing query for a MySQL thread id. " \
                "The query is not killed until the operator confirms the pending action."

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
        chat_session = server_context[:chat_session]
        return Mcp::Tools.unauthorized("Admin MySQL query interruption requires an admin chat context") unless chat_session&.user&.admin?

        inspector = Inspector.new
        process = inspector.process(thread_id)
        return Mcp::Tools.invalid("MySQL thread not found: #{thread_id}") unless process
        return Mcp::Tools.invalid("MySQL thread #{process[:id]} has no current statement") unless process[:info].present?

        query_details = {
          "thread_id" => process[:id],
          "statement" => process[:info],
          "user" => process[:user],
          "host" => process[:host],
          "database" => process[:database],
          "time_seconds" => process[:time_seconds],
          "query_state" => process[:state]
        }.compact
        pending_payload = query_details.merge("statement_verifier" => process[:statement_verifier])

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_mysql_kill_query",
          payload: pending_payload,
          message: "Kill the query on MySQL thread #{process[:id]}?",
          extra: query_details.symbolize_keys
        )
      rescue Inspector::Unavailable, ArgumentError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
      rescue StandardError => e
        Rails.logger.error("[AdminMysql::KillQueryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
