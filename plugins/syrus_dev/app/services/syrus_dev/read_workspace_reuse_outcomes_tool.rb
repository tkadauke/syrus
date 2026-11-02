require "mcp"

module SyrusDev
  class ReadWorkspaceReuseOutcomesTool < MCP::Tool
    tool_name "read_workspace_reuse_outcomes"

    description <<~DESC
      Read durable prepare-reuse and grader-workspace materialization outcomes
      for the current Syrus repository over a bounded time window.
    DESC

    input_schema(
      properties: {
        since: {
          type: "string",
          description: "Inclusive ISO 8601 window start. Defaults to 30 days ago."
        },
        until_time: {
          type: "string",
          description: "Inclusive ISO 8601 window end. Defaults to now."
        }
      }
    )

    class << self
      def call(server_context:, since: nil, until_time: nil)
        context = McpToolContext.from_server_context(server_context)
        return Mcp::Tools.not_authorized unless context.role == AgentRole::WORKFLOW_IMPLEMENT
        return Mcp::Tools.invalid("workspace reuse outcomes are only available for Syrus repositories") unless McpToolPolicy.syrus_repository?(context.repository)

        window_end = parse_time(until_time) || Time.current
        window_start = parse_time(since) || 30.days.ago
        return Mcp::Tools.invalid("since must be earlier than or equal to until_time") if window_start > window_end

        payload = {
          repository_id: context.repository.id,
          since: window_start.iso8601,
          until_time: window_end.iso8601,
          groups: WorkspaceReuseOutcomes::Summary.call(
            since: window_start,
            until_time: window_end,
            repository: context.repository
          )
        }
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue ArgumentError => error
        Mcp::Tools.invalid(error.message)
      rescue StandardError => error
        Rails.logger.error("[SyrusDev::ReadWorkspaceReuseOutcomesTool] #{error.class}: #{error.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{error.class}: #{error.message}" } ], error: true)
      end

      private

      def parse_time(value)
        return if value.blank?

        Time.iso8601(value)
      rescue ArgumentError
        raise ArgumentError, "timestamps must use ISO 8601"
      end
    end
  end
end
