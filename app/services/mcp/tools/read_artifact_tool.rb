require "mcp"

module Mcp::Tools
  # Chat-surface counterpart to SyrusMcp::ReadArtifactTool. Reads a
  # previously submitted image artifact back as actual image content for a
  # Workflow visible to this chat session's user -- a metadata-only echo
  # isn't sufficient, the point is to let the agent actually see the image.
  class ReadArtifactTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_artifact"

    description "Read a typed image artifact (e.g. a visual_review screenshot) from a Workflow visible to this chat session's user, returned as image content. Use list_artifacts first to find the `type` key."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Syrus Workflow id the artifact was recorded on." },
        type: { type: "string", description: "The artifact's `type` key, as returned by list_artifacts." }
      },
      required: %w[workflow_id type]
    )

    class << self
      def call(workflow_id:, type:, server_context:)
        workflow = find_workflow!(workflow_id)

        artifact_type = Mcp::Tools.utf8(type).strip
        return Mcp::Tools.invalid("type is required") if artifact_type.empty?

        attachment = workflow.visual_artifact_for(artifact_type)
        return Mcp::Tools.invalid("no image artifact found for type #{artifact_type.inspect}") unless attachment

        Mcp::Tools.image_result(jpeg: attachment.download, mime_type: attachment.content_type.presence || "image/png")
      end
    end
  end
end
