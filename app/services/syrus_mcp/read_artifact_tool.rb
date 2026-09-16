require "mcp"

module SyrusMcp
  # Reads a previously submitted image artifact (e.g. a visual_review
  # screenshot from SubmitVisualArtifactTool) back as actual image content,
  # the same way browser_screenshot already returns image content to an
  # agent -- a metadata-only echo isn't sufficient here. Use
  # ListArtifactsTool first to find the `type` key.
  class ReadArtifactTool < MCP::Tool
    tool_name "read_artifact"

    description <<~DESC
      Reads a previously submitted image artifact (e.g. a visual_review
      screenshot from submit_visual_artifact) back as actual image content,
      the same way browser_screenshot returns image content. Use
      list_artifacts first to find the `type` key -- only artifacts backed
      by an attached image can be read this way.
    DESC

    input_schema(
      properties: {
        workflow_id: {
          type: "integer",
          description: "Syrus Workflow id the artifact was recorded on. Must be in the same repository as the current Run."
        },
        type: {
          type: "string",
          description: "The artifact's `type` key, as returned by list_artifacts."
        }
      },
      required: %w[workflow_id type]
    )

    class << self
      def call(workflow_id:, type:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        workflow = find_workflow_in_scope(workflow_id, run)
        return Mcp::Tools.invalid("workflow_id is outside this repository scope") unless workflow

        artifact_type = Mcp::Tools.utf8(type).strip
        return Mcp::Tools.invalid("type is required") if artifact_type.empty?

        attachment = workflow.visual_artifact_for(artifact_type)
        return Mcp::Tools.invalid("no image artifact found for type #{artifact_type.inspect}") unless attachment

        Mcp::Tools.image_result(jpeg: attachment.download, mime_type: attachment.content_type.presence || "image/png")
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadArtifactTool] #{e.class}: #{e.message}")
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
    end
  end
end
