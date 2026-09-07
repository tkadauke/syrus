require "mcp"

module Mcp::Tools
  # MCP tool for the implementing agent to start the target application as
  # a background process in the workflow runner container. Delegates the
  # actual dev-server-start/health-check plumbing to PreviewProcessLauncher
  # (shared with SyrusBrowser::RuntimeSessionProvider) keyed by this Run's
  # id, so a repeat call within the same Run reuses the already-running
  # process instead of double-spawning.
  #
  # State is tracked in AgentPreviewRegistry for the lifetime of the sidecar
  # process. Sidecar#run registers an at_exit hook that kills all tracked
  # processes when the step ends.
  class StartPreviewTool < MCP::Tool
    tool_name "start_preview"

    description <<~DESC
      Start the target application as a background process in the workflow runner
      container. Runs the configured seed command (if any), spawns the app on the
      requested port, polls the health check path for up to 60 seconds, then returns
      the local URL and process ID on success.

      The preview is auto-killed when the workflow step ends. Call stop_preview when
      you no longer need the app running.
    DESC

    input_schema(
      properties: {
        port: {
          type: "integer",
          description: "TCP port to start the app on. Defaults to 3001."
        }
      }
    )

    class << self
      def call(port: 3001, server_context:)
        run = Mcp::Tools.run_from_context(server_context)

        workspace_path = workspace_path_for(run)
        return Mcp::Tools.invalid("no workflow workspace found") unless workspace_path

        result = PreviewProcessLauncher.new(workspace_path).launch!(key: run.id, port: port)
        Mcp::Tools.write_log(run, "[mcp] start_preview: pid=#{result.pid} port=#{port}") unless result.reused

        MCP::Tool::Response.new([{
          type: "text",
          text: JSON.generate({ url: result.url, pid: result.pid })
        }])
      rescue PreviewProcessLauncher::LaunchError => e
        MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }], error: true)
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::StartPreviewTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }], error: true)
      end

      private

      def workspace_path_for(run)
        step     = run.step
        return nil unless step
        workflow = step.workflow
        return nil unless workflow
        WorkflowWorkspace.path_for(workflow).to_s
      end
    end
  end
end
