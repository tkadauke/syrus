require "mcp"

module SyrusDev
  class ReadSyrusLogsTool < MCP::Tool
    extend DiagnosticsAuthorization

    tool_name "read_syrus_logs"

    DESCRIPTION = <<~DESC
      Search recent indexed Rails application logs for this Syrus instance.
      Available to workflow implementation and agent insight runs working on
      tkadauke/syrus or a registered fork, and to coworkers with the Syrus
      diagnostics grant.
    DESC

    description DESCRIPTION

    input_schema(properties: OperationalLogSearch::INPUT_SCHEMA_PROPERTIES)

    class << self
      def call(server_context:, query: nil, since: nil, level: nil, role: nil, hostname: nil, limit: 50)
        context = McpToolContext.from_server_context(server_context)
        unless coworker_diagnostics_authorized?(context)
          return Mcp::Tools.not_authorized unless authorized_role?(context.role)
          return Mcp::Tools.invalid("Syrus logs are only available for Syrus repositories") unless McpToolPolicy.syrus_repository?(context.repository)
        end
        return OperationalLogSearch.disabled_response unless OperationalLogging.enabled_for_instance?

        OperationalLogSearch.search_response(query: query, since: since, level: level, role: role, hostname: hostname, limit: limit)
      rescue StandardError => e
        Rails.logger.error("[SyrusDev::ReadSyrusLogsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def authorized_role?(role)
        role == AgentRole::WORKFLOW_IMPLEMENT || role == AgentRole::AGENT_INSIGHT
      end
    end
  end
end
