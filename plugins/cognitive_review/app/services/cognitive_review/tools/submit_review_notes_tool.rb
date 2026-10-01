require "digest"
require "mcp"

module CognitiveReview
  module Tools
    class SubmitReviewNotesTool < MCP::Tool
      tool_name "submit_review_notes"
      LEGACY_TOOL_NAMES = %w[submit_cognitive_review_notes].freeze

      MAX_NOTES = 20
      MAX_TEXT_LENGTH = 1_000

      description <<~DESC
        Submit review notes for changed diff ranges after an implementation workflow.
        Each note should read like concise review guidance and explain why that range is shaped the way it is.
        Submit an empty notes array when the diff has no attention-worthy ranges.
      DESC

      input_schema(
        properties: {
          notes: {
            type: "array",
            maxItems: MAX_NOTES,
            items: {
              type: "object",
              properties: {
                path: { type: "string", description: "Repository-relative file path." },
                side: { type: "string", enum: %w[new old], description: "Diff side for the range." },
                start_line: { type: "integer", minimum: 1 },
                end_line: { type: "integer", minimum: 1 },
                title: { type: "string", maxLength: 120 },
                summary: { type: "string", maxLength: 240 },
                explanation: { type: "string", maxLength: MAX_TEXT_LENGTH },
                body: { type: "string", maxLength: MAX_TEXT_LENGTH, description: "Deprecated alias for explanation." },
                reason_codes: { type: "array", items: { type: "string", maxLength: 80 } },
                category: { type: "string", maxLength: 80, description: "Deprecated alias appended to reason_codes." },
                confidence: { type: "number", minimum: 0.0, maximum: 1.0 },
                priority: { type: "string", enum: %w[low medium high] }
              },
              required: %w[path side start_line title]
            },
            description: "Diff-range notes worth surfacing to the operator. Use [] when there are no notes."
          }
        },
        required: %w[notes]
      )

      class << self
        def handles_tool_name?(name)
          tool_name == name || LEGACY_TOOL_NAMES.include?(name)
        end

        def call(notes:, server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          context = McpToolContext.from_run(run)
          return Mcp::Tools.unauthorized("submit_review_notes is only available to post-implementation review runs") unless CognitiveReview::McpToolSet.available_for_context?(context)

          normalized = normalize_notes(notes)
          return Mcp::Tools.invalid("notes must be an array of at most #{MAX_NOTES} items") unless normalized
          version = DiffReviewVersion.best_match_for(job_id: run.job_id, run_id: run.id, workflow_id: run.workflow_id)
          return Mcp::Tools.invalid("No diff review version is available for this run/workflow.") unless version

          if normalized.empty?
            CognitiveReview::Artifact.append!(run: run, notes: [], diff_review_version: version)
            Mcp::Tools.write_log(run, "[mcp] submit_review_notes received: 0 note(s)")
            return MCP::Tool::Response.new([ { type: "text", text: "Saved 0 review note(s)." } ])
          end

          saved_notes = normalized.map do |note|
            CognitiveReview::Note.upsert_from_submission!(
              run: run,
              diff_review_version: version,
              attributes: note.merge("source_metadata" => source_metadata(run: run, version: version))
            )
          end
          CognitiveReview::Artifact.append!(run: run, notes: normalized, diff_review_version: version)
          Mcp::Tools.write_log(run, "[mcp] submit_review_notes received: #{saved_notes.size} note(s)")

          MCP::Tool::Response.new([ { type: "text", text: "Saved #{saved_notes.size} review note(s)." } ])
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          Mcp::Tools.invalid(e.message)
        rescue StandardError => e
          Rails.logger.error("[CognitiveReview::Tools::SubmitReviewNotesTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def normalize_notes(notes)
          return unless notes.is_a?(Array)
          return if notes.size > MAX_NOTES

          notes.map.with_index do |note, index|
            normalize_note(note, index: index)
          end
        end

        def normalize_note(note, index:)
          raise ArgumentError, "notes[#{index}] must be an object" unless note.respond_to?(:to_h)

          attrs = note.to_h.with_indifferent_access
          path = text(attrs[:path])
          side = text(attrs[:side])
          start_line = positive_integer(attrs[:start_line])
          end_line = positive_integer(attrs[:end_line]) || start_line
          title = text(attrs[:title], max: 120)
          summary = text(attrs[:summary], max: 240)
          explanation = text(attrs[:explanation].presence || attrs[:body], max: MAX_TEXT_LENGTH)
          reason_codes = reason_codes(attrs)

          raise ArgumentError, "notes[#{index}].path is required" if path.blank?
          raise ArgumentError, "notes[#{index}].side must be new or old" unless %w[new old].include?(side)
          raise ArgumentError, "notes[#{index}].start_line must be positive" unless start_line
          raise ArgumentError, "notes[#{index}].title is required" if title.blank?
          raise ArgumentError, "notes[#{index}].explanation is required" if explanation.blank?

          {
            "path" => path,
            "side" => side,
            "start_line" => [ start_line, end_line ].min,
            "end_line" => [ start_line, end_line ].max,
            "title" => title,
            "summary" => summary.presence,
            "explanation" => explanation,
            "reason_codes" => reason_codes,
            "confidence" => confidence(attrs[:confidence]),
            "priority" => priority(attrs[:priority])
          }.compact
        end

        def text(value, max: MAX_TEXT_LENGTH)
          Mcp::Tools.utf8(value).strip.truncate(max)
        end

        def positive_integer(value)
          Integer(value, exception: false).then { |number| number if number&.positive? }
        end

        def confidence(value)
          return if value.blank?

          number = Float(value, exception: false)
          return unless number

          number.clamp(0.0, 1.0)
        end

        def reason_codes(attrs)
          values = Array(attrs[:reason_codes]).map { |value| text(value, max: 80) }
          values << text(attrs[:category], max: 80) if attrs[:category].present?
          values.reject(&:blank?).uniq
        end

        def priority(value)
          normalized = text(value, max: 20)
          return "medium" if normalized.blank?
          return normalized if CognitiveReview::Note::PRIORITIES.include?(normalized)

          raise ArgumentError, "priority must be low, medium, or high"
        end

        def source_metadata(run:, version:)
          {
            "run_id" => run.id,
            "workflow_id" => run.workflow_id,
            "job_id" => run.job_id,
            "diff_review_version_id" => version.id,
            "base_sha" => version.base_sha,
            "head_sha" => version.head_sha,
            "agent_provider" => run.agent_provider,
            "model" => run.model,
            "prompt_sha256" => Digest::SHA256.hexdigest(run.prompt.to_s)
          }.compact
        end
      end
    end
  end
end
