require "mcp"

module SyrusMcp
  # MCP tool for the agent to stop the background preview process it
  # started with start_preview. Safe to call even when no preview is
  # running — the registry miss is a no-op. The process is also killed
  # automatically at sidecar exit, so stop_preview is purely advisory.
  class StopPreviewTool < MCP::Tool
    tool_name "stop_preview"

    description "Stop the background preview process started with start_preview. Safe to call even if no preview is running — the process is also killed automatically when the workflow step ends."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        run = SyrusMcp.run_from_context(server_context)
        AgentPreviewRegistry.kill(run.id)
        SyrusMcp.write_log(run, "[mcp] stop_preview: requested")
        MCP::Tool::Response.new([{ type: "text", text: "Preview stopped." }])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::StopPreviewTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }], error: true)
      end
    end
  end
end
