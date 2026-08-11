require "mcp"

module Mcp::Tools
  # Chat-surface counterpart to SyrusMcp::SubmitArtifactTool. Stores a typed,
  # named artifact on the current ChatSession under the 'typed_artifacts' key
  # in ChatSession#artifacts instead of a workflow Run's Workflow. Same
  # idempotency (replace-on-type-match) and validation as the workflow tool.
  class SubmitArtifactTool < MCP::Tool
    tool_name "submit_artifact"

    description <<~DESC
      Stores a typed, named artifact on the current chat session.
      The Syrus harness persists this under the 'typed_artifacts' key in the
      chat session's artifact store, and it appears in the chat Media
      library. type is a free-form string identifier (e.g.
      'rails_schema_erd', 'rails_migration_diff'); payload is an arbitrary JSON
      object. If an entry with the same type already exists, it is replaced.
    DESC

    input_schema(
      properties: {
        type: {
          type: "string",
          description: "Artifact type identifier (e.g. 'rails_schema_erd', 'rails_migration_diff')."
        },
        title: {
          type: "string",
          description: "Human-readable title for the artifact."
        },
        payload: {
          type: "object",
          description: "Artifact data as a JSON object. Schema is defined by the artifact type."
        }
      },
      required: %w[type title payload]
    )

    class << self
      def call(type:, title:, payload:, server_context:)
        chat_session = server_context.fetch(:chat_session)

        artifact_type  = Mcp::Tools.utf8(type).strip
        artifact_title = Mcp::Tools.utf8(title).strip

        return Mcp::Tools.invalid("type is required")           if artifact_type.empty?
        return Mcp::Tools.invalid("title is required")          if artifact_title.empty?
        return Mcp::Tools.invalid("payload must be an object")  unless payload.is_a?(Hash)

        entry = {
          "type"       => artifact_type,
          "title"      => artifact_title,
          "payload"    => payload,
          "created_at" => Time.current.iso8601
        }

        existing = Array(chat_session.artifact("typed_artifacts"))
        updated  = existing.reject { |e| e["type"] == artifact_type }
        updated << entry

        chat_session.set_artifact!("typed_artifacts", updated)

        Mcp::Tools.success(message: "Saved.")
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitArtifactTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
