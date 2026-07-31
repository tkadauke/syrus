require "mcp"

module SyrusMcp
  # MCP tool for the agent to read the last N lines from the preview
  # application's log file. Useful when an HTTP response is unexpected
  # and the agent needs to see what the app emitted.
  #
  # Defaults to the first path in the log_paths config from .syrus.yml
  # or the preview plugin. The caller may supply an explicit path
  # (relative to the workspace root) to read a different log file.
  # Absolute paths supplied by the agent must still fall within the
  # workspace to prevent path traversal.
  class ReadPreviewLogTool < MCP::Tool
    tool_name "read_preview_log"

    description <<~DESC
      Read the last N lines from the preview app's log file. Useful when an HTTP
      response is unexpected and you need to see what the app printed. Defaults to
      the first log path configured in .syrus.yml or the preview plugin; supply
      path to read a different log file (relative to the workspace root).
    DESC

    input_schema(
      properties: {
        path: {
          type: "string",
          description: "Path to the log file, relative to the workspace root (or absolute within it). Defaults to the first configured log path."
        },
        lines: {
          type: "integer",
          description: "Number of trailing lines to return. Defaults to 100, max 1000."
        }
      }
    )

    DEFAULT_LINES = 100
    MAX_LINES     = 1000

    class << self
      def call(path: nil, lines: DEFAULT_LINES, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        workspace_path = workspace_path_for(run)
        return SyrusMcp.invalid("no workflow workspace found") unless workspace_path

        line_count = clamp_lines(lines)
        log_path   = resolve_log_path(path, workspace_path)
        return SyrusMcp.invalid("no log path configured and none specified") unless log_path
        return SyrusMcp.invalid("log file not found: #{log_path}") unless File.exist?(log_path)

        content = tail_file(log_path, line_count)

        MCP::Tool::Response.new([{
          type: "text",
          text: "#{log_path} (last #{line_count} lines):\n#{content}"
        }])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadPreviewLogTool] #{e.class}: #{e.message}")
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

      def clamp_lines(lines)
        [[Integer(lines.to_i), 1].max, MAX_LINES].min
      end

      # Agent-supplied paths are restricted to within the workspace (path
      # traversal guard). Config-supplied log_paths may be absolute (operator-
      # controlled), so they're trusted as-is; relative config paths are
      # expanded against the workspace root.
      def resolve_log_path(path, workspace_path)
        if path.present?
          resolved       = File.expand_path(path, workspace_path)
          safe_workspace = File.expand_path(workspace_path)
          return nil unless resolved.start_with?(safe_workspace + "/") || resolved == safe_workspace
          resolved
        else
          source   = PreviewCommandSource.new(workspace_path).resolve
          raw_path = source&.log_paths&.first
          return nil unless raw_path.present?
          Pathname.new(raw_path).absolute? ? raw_path : File.expand_path(raw_path, workspace_path)
        end
      end

      def tail_file(path, n)
        File.readlines(path, chomp: true).last(n).join("\n")
      rescue Errno::ENOENT
        "(log file disappeared)"
      end
    end
  end
end
