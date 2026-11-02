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
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        with_provider_call(session) do |provider|
          provider.snapshot(session.id, { artifact_type: artifact_type, checkpoint_label: checkpoint_label }.compact)
        end
      end
    end
  end
end
