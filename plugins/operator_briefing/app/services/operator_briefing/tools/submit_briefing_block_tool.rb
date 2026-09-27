require "mcp"

module OperatorBriefing
  module Tools
    class SubmitBriefingBlockTool < MCP::Tool
      tool_name "submit_briefing_block"

      description <<~DESC
        Appends one typed content block to the current Operator Briefing revision
        and streams it to the live /briefing page. Call once per completed
        section instead of waiting to submit the whole briefing.
      DESC

      input_schema(
        properties: {
          kind: {
            type: "string",
            enum: BriefingRevision::BLOCK_KINDS,
            description: "Typed block kind to append."
          },
          payload: {
            type: "object",
            description: "Block payload matching the selected kind."
          }
        },
        required: %w[kind payload]
      )

      class << self
        def call(kind:, payload:, server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          unless run.step&.kind == "briefing_generate_run"
            return Mcp::Tools.invalid("submit_briefing_block is only available from briefing_generate_run")
          end

          revision = BriefingRevision.find_by!(generation_run: run)
          normalized = normalize_block(kind, payload)
          return normalized if normalized.is_a?(MCP::Tool::Response)

          block = revision.append_block!(normalized)
          run.workflow.set_artifact!("briefing_revision_id", revision.id)
          Mcp::Tools.write_log(run, "[mcp] submit_briefing_block: #{block.fetch('kind')}")

          Mcp::Tools.success(
            briefing_id: revision.briefing_id,
            revision_id: revision.id,
            revision_number: revision.revision_number,
            block_count: revision.reload.content_blocks.size
          )
        rescue ActiveRecord::RecordNotFound
          Mcp::Tools.invalid("no active Operator Briefing revision exists for this run")
        rescue ActiveRecord::RecordInvalid => e
          Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
        rescue StandardError => e
          Rails.logger.error("[OperatorBriefing::Tools::SubmitBriefingBlockTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def normalize_block(kind, payload)
          kind_s = Mcp::Tools.utf8(kind).strip
          return Mcp::Tools.invalid("kind must be one of: #{BriefingRevision::BLOCK_KINDS.join(', ')}") unless BriefingRevision::BLOCK_KINDS.include?(kind_s)
          return Mcp::Tools.invalid("payload must be an object") unless payload.is_a?(Hash)

          { "kind" => kind_s, "payload" => payload.deep_stringify_keys }
        end
      end
    end
  end
end
