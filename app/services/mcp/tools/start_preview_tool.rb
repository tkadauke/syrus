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
        },
        project_id: {
          type: "string",
          description: "Affected preview project id to start when the workflow lists multiple project previews. Optional when there is exactly one affected preview project."
        }
      }
    )

    class << self
      def call(port: 3001, project_id: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)

        workspace_path = workspace_path_for(run)
        return Mcp::Tools.invalid("no workflow workspace found") unless workspace_path

        project_id = resolve_project_id(run, project_id)
        result = PreviewProcessLauncher.new(workspace_path, project_id: project_id).launch!(
          key: preview_key(run, project_id),
          port: port
        )
        log_start(run, result, port) unless result.reused

        MCP::Tool::Response.new([{
          type: "text",
          text: JSON.generate({ url: result.url, pid: result.pid, project_id: result.project_id }.compact)
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

      def resolve_project_id(run, requested_project_id)
        projects = Array(run.step&.workflow&.artifact("visual_review_preview_projects"))
        requested_project_id = requested_project_id.to_s.strip.presence
        return requested_project_id if projects.empty?

        return projects.first.fetch("id") if requested_project_id.blank? && projects.one?
        if requested_project_id.blank?
          raise PreviewProcessLauncher::LaunchError,
            "multiple affected preview projects are available; pass project_id (#{projects.map { |project| project['id'] }.join(', ')})"
        end

        unless projects.any? { |project| project["id"] == requested_project_id }
          raise PreviewProcessLauncher::LaunchError,
            "project_id #{requested_project_id.inspect} is not an affected preview project for this visual review"
        end

        requested_project_id
      end

      def preview_key(run, project_id)
        project_id.present? ? "#{run.id}:#{project_id}" : run.id
      end

      def log_start(run, result, port)
        detail = "[mcp] start_preview: pid=#{result.pid} port=#{port}"
        detail = "#{detail} project_id=#{result.project_id}" if result.project_id.present?
        Mcp::Tools.write_log(run, detail)
      end
    end
  end
end
