require "mcp"

module Mcp::Tools
  class RuntimeCaptureArtifactTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_capture_artifact"

    description <<~DESC
      Capture evidence from a Runtime Session (DOC-17), delegating to the
      provider's snapshot capability and returning the same provider-neutral
      image/artifact metadata as `runtime_snapshot`. `artifact_type` is an
      optional hint some providers may use to pick which kind of evidence to
      capture. Defaults to the chat's primary active session when `session_id`
      is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        artifact_type: { type: "string", description: "Optional hint for which kind of evidence to capture (e.g. \"screenshot\")." },
        checkpoint_label: { type: "string", description: "Optional short label describing the captured checkpoint." }
      }
    )

    class << self
      def call(session_id: nil, artifact_type: nil, checkpoint_label: nil, server_context:)
        owner, guard = runtime_owner_from(server_context)
        return guard if guard

        session, error = resolve_runtime_session(owner, session_id)
        return error if error

        with_provider_call(session) do |provider|
          result = provider.snapshot(session.id, { artifact_type: artifact_type, checkpoint_label: checkpoint_label }.compact)
          persist_workflow_capture(owner, result, artifact_type: artifact_type, checkpoint_label: checkpoint_label)
          result
        end
      end

      private

      def persist_workflow_capture(owner, result, artifact_type:, checkpoint_label:)
        return unless owner.is_a?(Run)

        content = result.to_h[:content] || result.to_h["content"]
        image = Array(content).find do |block|
          block.to_h[:type].to_s == "image" || block.to_h["type"].to_s == "image"
        end
        return unless image

        image = image.to_h
        response = SyrusMcp::SubmitVisualArtifactTool.call(
          type: artifact_type.presence || "visual_review_runtime_screenshot",
          title: checkpoint_label.presence || "Runtime screenshot",
          image_base64: image[:data] || image["data"],
          content_type: image[:mimeType] || image["mimeType"] || image[:mime_type] || image["mime_type"],
          server_context: { run: owner }
        )
        raise "runtime screenshot could not be persisted" if response.error?
      end
    end
  end
end
