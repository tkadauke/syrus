require "mcp"

module Mcp::Tools
  # Chat-surface counterpart to SyrusMcp::ListArtifactsTool. Lists the
  # typed_artifacts entries recorded on a Workflow visible to this chat
  # session's user, including visual_review screenshots submitted via
  # SyrusMcp::SubmitVisualArtifactTool during a workflow run.
  class ListArtifactsTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "list_artifacts"

    description "List typed artifacts (including visual review screenshots) recorded on a Workflow visible to this chat session's user."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Syrus Workflow id to list artifacts for." }
      },
      required: %w[workflow_id]
    )

    class << self
      def call(workflow_id:, server_context:)
        workflow = find_workflow!(workflow_id)

        Mcp::Tools.success(workflow_id: workflow.id, artifacts: artifact_summaries(workflow))
      end

      private

      def artifact_summaries(workflow)
        Array(workflow.artifact("typed_artifacts")).filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["type"].present?

          payload = entry["payload"].is_a?(Hash) ? entry["payload"] : {}
          {
            type: entry["type"],
            title: entry["title"],
            content_type: payload["content_type"],
            byte_size: payload["byte_size"],
            run_id: entry["run_id"] || payload["run_id"],
            step_id: entry["step_id"] || payload["step_id"],
            iteration: payload["iteration"],
            image_url: payload["image_url"]
          }
        end
      end
    end
  end
end
