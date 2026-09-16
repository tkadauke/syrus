require "mcp"

module SyrusMcp
  # Companion read tool to SubmitArtifactTool/SubmitVisualArtifactTool: lists
  # the typed_artifacts entries recorded on a Workflow so an agent can
  # discover what's been captured -- including visual_review screenshots --
  # without guessing the `type` key used at submit time. Pass a listed
  # `type` to ReadArtifactTool to fetch an image artifact's actual content.
  class ListArtifactsTool < MCP::Tool
    tool_name "list_artifacts"

    description <<~DESC
      Lists the typed_artifacts entries recorded on a Workflow (written by
      submit_artifact / submit_visual_artifact), including visual review
      screenshots. Returns type, title, content_type, byte_size, run_id,
      step_id, iteration, and image_url per entry so an agent can find the
      `type` key to pass to read_artifact without guessing.
    DESC

    input_schema(
      properties: {
        workflow_id: {
          type: "integer",
          description: "Syrus Workflow id to list artifacts for. Must be in the same repository as the current Run."
        }
      },
      required: %w[workflow_id]
    )

    class << self
      def call(workflow_id:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        workflow = find_workflow_in_scope(workflow_id, run)
        return Mcp::Tools.invalid("workflow_id is outside this repository scope") unless workflow

        Mcp::Tools.success(workflow_id: workflow.id, artifacts: artifact_summaries(workflow))
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ListArtifactsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def find_workflow_in_scope(workflow_id, run)
        workflow = Workflow.includes(job: :repository).find_by(id: workflow_id)
        return unless workflow
        return unless workflow.job.user_id == run.job.user_id
        return unless workflow.job.repository_id == run.job.repository_id

        workflow
      end

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
