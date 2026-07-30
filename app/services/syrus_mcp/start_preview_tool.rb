require "mcp"
require "net/http"

module SyrusMcp
  # MCP tool for the implementing agent to start the target application as
  # a background process in the workflow runner container. Resolves the
  # preview start command from .syrus.yml or a registered plugin, runs any
  # configured seed command, spawns the app, and polls the health check
  # path until the app is ready (up to 60 s).
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

    HEALTH_CHECK_TIMEOUT_SECONDS = 60
    HEALTH_CHECK_INTERVAL_SECONDS = 2

    class << self
      def call(port: 3001, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        workspace_path = workspace_path_for(run)
        return SyrusMcp.invalid("no workflow workspace found") unless workspace_path

        # Return the existing preview rather than double-spawning.
        existing = AgentPreviewRegistry.get(run.id)
        if existing
          return MCP::Tool::Response.new([{
            type: "text",
            text: JSON.generate({ url: "http://localhost:#{existing[:port]}", pid: existing[:pid] })
          }])
        end

        source = PreviewCommandSource.new(workspace_path).resolve
        return SyrusMcp.invalid("no preview command configured — add a preview: section to .syrus.yml") unless source

        run_seed!(source, workspace_path) if source.seed_command

        command = source.start_command_for.call(port: port)
        pid     = spawn_app(command, workspace_path, port)
        AgentPreviewRegistry.register(run_id: run.id, pid: pid, port: port)

        begin
          health_path = source.health_check_path.presence || "/"
          await_health_check!("http://127.0.0.1:#{port}#{health_path}")
        rescue => e
          AgentPreviewRegistry.kill(run.id)
          raise e
        end

        SyrusMcp.write_log(run, "[mcp] start_preview: pid=#{pid} port=#{port}")

        MCP::Tool::Response.new([{
          type: "text",
          text: JSON.generate({ url: "http://localhost:#{port}", pid: pid })
        }])
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

      def run_seed!(source, workspace_path)
        system(source.seed_command, chdir: workspace_path, exception: false)
      end

      def spawn_app(command, workspace_path, port)
        env = { "PORT" => port.to_s }
        Process.spawn(env, command, chdir: workspace_path, pgroup: true,
                                    out: "/dev/null", err: "/dev/null")
      end

      def await_health_check!(url)
        deadline = Time.current + HEALTH_CHECK_TIMEOUT_SECONDS
        loop do
          raise "preview health check timed out after #{HEALTH_CHECK_TIMEOUT_SECONDS}s" if Time.current > deadline
          return if http_ok?(url)
          sleep HEALTH_CHECK_INTERVAL_SECONDS
        end
      end

      def http_ok?(url)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
          http.get(uri.request_uri)
        end
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError
        false
      end
    end
  end
end
