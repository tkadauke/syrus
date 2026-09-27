require "mcp"

module OperatorBriefing
  module Tools
    class SubmitBriefingBlockTool < MCP::Tool
      KINDS = %w[narrative link_card].freeze

      tool_name "submit_briefing_block"

      description <<~DESC
        Append a structured content block to the current Operator Briefing revision.
        This phase accepts narrative and link_card blocks only.
      DESC

      input_schema(
        properties: {
          kind: {
            type: "string",
            enum: KINDS,
            description: "Block kind: narrative or link_card."
          },
          payload: {
            type: "object",
            description: "For narrative: {text}. For link_card: {entity_type, entity_id, title, path, description}."
          }
        },
        required: %w[kind payload]
      )

      class << self
        def call(kind:, payload:, server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          briefing = Briefing.find_by!(job: run.job)
          revision = BriefingRevision.find_by!(briefing: briefing, generation_run: run)
          normalized = normalize_block(kind, payload)
          return normalized if normalized.is_a?(MCP::Tool::Response)

          revision.with_lock do
            revision.content_blocks = Array(revision.content_blocks) + [ normalized ]
            revision.save!
          end
          run.workflow.set_artifact!("briefing_revision_id", revision.id)
          Mcp::Tools.write_log(run, "[mcp] submit_briefing_block: #{normalized.fetch('kind')}")

          MCP::Tool::Response.new([ { type: "text", text: "Briefing block saved to revision #{revision.revision_number}." } ])
        rescue ActiveRecord::RecordNotFound => e
          Mcp::Tools.invalid(e.message)
        rescue StandardError => e
          Rails.logger.error("[OperatorBriefing::SubmitBriefingBlockTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def normalize_block(kind, payload)
          kind_s = Mcp::Tools.utf8(kind).strip
          return Mcp::Tools.invalid("kind must be one of: #{KINDS.join(', ')}") unless KINDS.include?(kind_s)
          return Mcp::Tools.invalid("payload must be an object") unless payload.is_a?(Hash)

          normalized_payload = send("normalize_#{kind_s}", payload)
          return normalized_payload if normalized_payload.is_a?(MCP::Tool::Response)

          { "kind" => kind_s, "payload" => normalized_payload }
        end

        def normalize_narrative(payload)
          text = redact_string(payload["text"] || payload[:text])
          return Mcp::Tools.invalid("payload.text is required for narrative blocks") if text.blank?

          { "text" => text }
        end

        def normalize_link_card(payload)
          title = redact_string(payload["title"] || payload[:title])
          path = redact_string(payload["path"] || payload[:path])
          return Mcp::Tools.invalid("payload.title is required for link_card blocks") if title.blank?
          return Mcp::Tools.invalid("payload.path is required for link_card blocks") if path.blank?

          {
            "entity_type" => redact_string(payload["entity_type"] || payload[:entity_type]),
            "entity_id" => payload["entity_id"] || payload[:entity_id],
            "title" => title,
            "path" => path,
            "description" => redact_string(payload["description"] || payload[:description])
          }.compact
        end

        def redact_string(value)
          CommandRedactor.redact(Mcp::Tools.utf8(value)).strip
        end
      end
    end
  end
end
