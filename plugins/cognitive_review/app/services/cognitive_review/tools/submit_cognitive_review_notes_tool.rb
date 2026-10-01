require "mcp"

module CognitiveReview
  module Tools
    class SubmitCognitiveReviewNotesTool < MCP::Tool
      tool_name "submit_cognitive_review_notes"

      MAX_NOTES = 20
      MAX_TEXT_LENGTH = 1_000

      description <<~DESC
        Submit cognitive review notes for changed diff ranges after an implementation workflow.
        Each note should identify the file/range and explain why that range deserves operator attention.
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
                body: { type: "string", maxLength: MAX_TEXT_LENGTH },
                category: { type: "string", maxLength: 80 },
                confidence: { type: "number", minimum: 0.0, maximum: 1.0 }
              },
              required: %w[path side start_line title body]
            },
            description: "Diff-range notes worth surfacing to the operator. Use [] when there are no notes."
          }
        },
        required: %w[notes]
      )

      class << self
        def call(notes:, server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          context = McpToolContext.from_run(run)
          return Mcp::Tools.unauthorized("submit_cognitive_review_notes is only available to post-implementation review runs") unless CognitiveReview::McpToolSet.available_for_context?(context)

          normalized = normalize_notes(notes)
          return Mcp::Tools.invalid("notes must be an array of at most #{MAX_NOTES} items") unless normalized

          Artifact.append!(run: run, notes: normalized)
          Mcp::Tools.write_log(run, "[mcp] submit_cognitive_review_notes received: #{normalized.size} note(s)")

          MCP::Tool::Response.new([ { type: "text", text: "Saved #{normalized.size} cognitive review note(s)." } ])
        rescue StandardError => e
          Rails.logger.error("[CognitiveReview::Tools::SubmitCognitiveReviewNotesTool] #{e.class}: #{e.message}")
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
          attrs = note.to_h.with_indifferent_access
          path = text(attrs[:path])
          side = text(attrs[:side])
          start_line = positive_integer(attrs[:start_line])
          end_line = positive_integer(attrs[:end_line]) || start_line
          title = text(attrs[:title], max: 120)
          body = text(attrs[:body], max: MAX_TEXT_LENGTH)

          raise ArgumentError, "notes[#{index}].path is required" if path.blank?
          raise ArgumentError, "notes[#{index}].side must be new or old" unless %w[new old].include?(side)
          raise ArgumentError, "notes[#{index}].start_line must be positive" unless start_line
          raise ArgumentError, "notes[#{index}].title is required" if title.blank?
          raise ArgumentError, "notes[#{index}].body is required" if body.blank?

          {
            "id" => "cognitive-review-#{index + 1}",
            "path" => path,
            "side" => side,
            "start_line" => [ start_line, end_line ].min,
            "end_line" => [ start_line, end_line ].max,
            "title" => title,
            "body" => body,
            "category" => text(attrs[:category], max: 80).presence,
            "confidence" => confidence(attrs[:confidence]),
            "tone" => "warning"
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
      end
    end
  end
end
