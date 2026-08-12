require "mcp"

module Mcp::Tools
  class AdminReadOperationalLogsTool < MCP::Tool
    tool_name "admin_read_operational_logs"

    DESCRIPTION = <<~DESC
      Search recent indexed Rails application logs for this Syrus instance.
      Admin-only chat tool.
    DESC

    description DESCRIPTION

    input_schema(properties: OperationalLogSearch::INPUT_SCHEMA_PROPERTIES)

    class << self
      def call(server_context:, query: nil, since: nil, level: nil, role: nil, hostname: nil, limit: 50)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)
        return OperationalLogSearch.disabled_response unless OperationalLogging.enabled_for_instance?

        OperationalLogSearch.search_response(query: query, since: since, level: level, role: role, hostname: hostname, limit: limit)
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::AdminReadOperationalLogsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end
    end
  end
end
