require "mcp"

module Mcp::Tools
  class ReadLiveStateTool < MCP::Tool
    tool_name "read_live_state"

    description <<~DESC
      Read the current Syrus Job, Workflow, Run, queue, and related chat state for this agent run.
      This is read-only and scoped to the active MCP sidecar run; it does not accept arbitrary Job ids.
      Use it before making claims about current Syrus operational state when prompt text may be stale.
    DESC

    input_schema(
      properties: {
        detail: {
          type: "string",
          enum: %w[compact full],
          description: "Response detail level. Defaults to compact; full includes recent workflow steps and recent chat message snippets."
        }
      }
    )

    class << self
      def call(server_context:, detail: "compact")
        run = Mcp::Tools.run_from_context(server_context)
        payload = Mcp::Tools::LiveState.new(run).as_json(detail: detail)

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReadLiveStateTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
