require "mcp"

module SyrusMcp
  # Stores a typed, named artifact on the current Workflow under the
  # 'typed_artifacts' key in Workflow#artifacts. If an entry with the same
  # type already exists, it is replaced (idempotent on type).
  class SubmitArtifactTool < MCP::Tool
    tool_name "submit_artifact"

    description <<~DESC
      Stores a typed, named artifact on the current Workflow.
      The Syrus harness persists this under the 'typed_artifacts' key in the
      workflow artifact store. type is a free-form string identifier (e.g.
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
        run = SyrusMcp.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return SyrusMcp.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_artifact)

        artifact_type  = SyrusMcp.utf8(type).strip
        artifact_title = SyrusMcp.utf8(title).strip

        return SyrusMcp.invalid("type is required")           if artifact_type.empty?
        return SyrusMcp.invalid("title is required")          if artifact_title.empty?
        return SyrusMcp.invalid("payload must be an object")  unless payload.is_a?(Hash)

        entry = {
          "type"       => artifact_type,
          "title"      => artifact_title,
          "payload"    => payload,
          "created_at" => Time.current.iso8601
        }

        workflow = run.workflow
        existing = Array(workflow.artifact("typed_artifacts"))
        updated  = existing.reject { |e| e["type"] == artifact_type }
        updated << entry

        workflow.set_artifact!("typed_artifacts", updated)
        SyrusMcp.write_log(run, "[mcp] submit_artifact: #{artifact_type.inspect} — #{artifact_title.truncate(60)}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitArtifactTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
