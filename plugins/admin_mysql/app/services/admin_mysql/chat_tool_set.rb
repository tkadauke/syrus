require "mcp"

module AdminMysql
  class ChatToolSet
    def self.available_for?(chat_session, tier:)
      chat_session.user.admin? && AdminMysql.mysql? && %i[ essential deferred ].include?(tier.to_sym)
    end

    def self.tool_definitions(tier:)
      [
        {
          name: "admin_mysql_status",
          description: "Read live MySQL status, process list, connection information, slow-log availability, and statement digests for this Syrus instance.",
          input_schema: {
            type: "object",
            properties: {
              limit: {
                type: "integer",
                minimum: 1,
                maximum: Inspector::MAX_LIMIT,
                description: "Maximum number of process list rows to return."
              }
            }
          }
        },
        {
          name: "admin_mysql_kill_query",
          description: "Kill the currently executing query for a MySQL thread id using KILL QUERY. This does not close the connection.",
          input_schema: {
            type: "object",
            required: [ "thread_id" ],
            properties: {
              thread_id: {
                type: "integer",
                minimum: 1,
                description: "MySQL PROCESSLIST.ID to interrupt."
              }
            }
          }
        }
      ]
    end

    def handle(tool_name, params, _server_context)
      payload = case tool_name.to_s
      when "admin_mysql_status"
        Inspector.new.snapshot(limit: params[:limit] || params["limit"] || Inspector::DEFAULT_LIMIT)
      when "admin_mysql_kill_query"
        Inspector.new.kill_query(params[:thread_id] || params["thread_id"])
      else
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown Admin MySQL tool: #{tool_name.inspect}" } ], error: true)
      end

      MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: payload.dig(:error).present?)
    rescue Inspector::Unavailable, ArgumentError => e
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.message}" } ], error: true)
    rescue StandardError => e
      Rails.logger.error("[AdminMysql::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end
  end
end
