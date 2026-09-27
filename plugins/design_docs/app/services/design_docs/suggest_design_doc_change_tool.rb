require "mcp"

module DesignDocs
  class SuggestDesignDocChangeTool < MCP::Tool
    extend ToolSupport

    tool_name "suggest_design_doc_change"

    description "Suggest a change to existing DOC-<id> content. Chat-agent content writes are suggestion-only: this always creates a pending suggestion and never directly mutates canonical Markdown. Pass the current_version_number returned by read_design_doc as base_version_number. Prefer original_markdown to locate the current text; use occurrence_index after an ambiguity error, or offsets when you already know the exact range. After creating a suggestion, re-read the Design Doc before creating another suggestion."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123." },
        start_offset: { type: "integer", description: "Optional rendered Markdown start offset for the changed range. Offsets must land at the document start/end, a blank-line boundary, or immediately before a heading, list item, blockquote, or code fence marker when the selection includes Markdown block syntax." },
        end_offset: { type: "integer", description: "Optional rendered Markdown end offset for the changed range. Offsets must land at the document start/end, a blank-line boundary, or immediately before a heading, list item, blockquote, or code fence marker when the selection includes Markdown block syntax." },
        base_version_number: { type: "integer", description: "The current_version_number returned by the read_design_doc call used to calculate this suggestion. Re-read the Design Doc after any successful suggestion before sending another suggestion." },
        original_markdown: { type: "string", description: "Current rendered Markdown to replace. When offsets are omitted, this text is matched against the current rendered_markdown and must be unique unless occurrence_index is supplied. When offsets are supplied, it must exactly match the live text in that range." },
        occurrence_index: { type: "integer", description: "Optional 1-based occurrence number to use when original_markdown appears more than once. Retry with an occurrence_index from the ambiguity error, or include more surrounding text in original_markdown to make it unique." },
        proposed_markdown: { type: "string", description: "Replacement Markdown for the selected range. The owner must accept the pending suggestion before it becomes canonical." },
        change_summary: { type: "string", description: "Short summary of the suggested change." },
        thread_id: { type: "integer", description: "Optional existing design-doc thread id to attach the suggestion to." }
      },
      required: %w[doc_ref base_version_number proposed_markdown]
    )

    class << self
      AMBIGUOUS_MATCH_LIMIT = 10
      CONTEXT_LINES = 2

      def call(doc_ref:, proposed_markdown:, server_context:, start_offset: nil, end_offset: nil, base_version_number: nil, original_markdown: nil, occurrence_index: nil, change_summary: nil, thread_id: nil)
        return invalid("suggest_design_doc_change is only available in chat contexts") unless chat_context?(server_context)

        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        current_version_number = design_doc.current_version&.version_number
        if base_version_number.blank?
          return invalid(
            "base_version_number is required for #{design_doc.display_id}. Re-read the Design Doc and pass its current_version_number before creating an offset-based suggestion."
          )
        end

        if current_version_number.present? && base_version_number.to_i != current_version_number
          return invalid(
            "stale design doc offsets for #{design_doc.display_id}: base_version_number #{base_version_number} does not match current_version_number #{current_version_number}. Re-read the Design Doc before creating another offset-based suggestion."
          )
        end

        offsets = resolve_offsets(
          design_doc: design_doc,
          start_offset: start_offset,
          end_offset: end_offset,
          original_markdown: original_markdown,
          occurrence_index: occurrence_index
        )
        return invalid(offsets.error) if offsets.error

        result = DesignDocs::CreateSuggestion.call(
          design_doc: design_doc,
          user: context.user,
          actor_kind: "agent",
          attributes: {
            start_offset: offsets.start_offset,
            end_offset: offsets.end_offset,
            original_markdown: original_markdown,
            proposed_markdown: proposed_markdown,
            change_summary: change_summary,
            thread_id: thread_id
          }.merge(agent_actor_attributes(server_context))
        )

        success(suggestion_payload(result))
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.full_messages.to_sentence)
      rescue Pundit::NotAuthorizedError
        invalid("not allowed to suggest changes to #{doc_ref}")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::SuggestDesignDocChangeTool] #{e.class}: #{e.message}")
        tool_error("Could not suggest design doc change: #{e.message}")
      end

      private

      ResolvedOffsets = Data.define(:start_offset, :end_offset, :error)

      def resolve_offsets(design_doc:, start_offset:, end_offset:, original_markdown:, occurrence_index:)
        has_start = start_offset.present?
        has_end = end_offset.present?
        return ResolvedOffsets.new(start_offset: start_offset, end_offset: end_offset, error: nil) if has_start && has_end
        return ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: "start_offset and end_offset must be supplied together.") if has_start || has_end
        return ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: "Either original_markdown or both start_offset and end_offset is required to locate the suggested change.") if original_markdown.blank?

        visible = AnchorMarkers.strip(design_doc.markdown)
        matches = AnchorMarkers.exact_matches(visible, original_markdown)
        return ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: missing_match_message(design_doc)) if matches.empty?

        if occurrence_index.present?
          occurrence = occurrence_index.to_i
          return ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: "occurrence_index must be between 1 and #{matches.length} for this original_markdown.") if occurrence < 1 || occurrence > matches.length

          start = matches.fetch(occurrence - 1)
          return ResolvedOffsets.new(start_offset: start, end_offset: start + original_markdown.length, error: nil)
        end

        return ResolvedOffsets.new(start_offset: matches.first, end_offset: matches.first + original_markdown.length, error: nil) if matches.one?
        return ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: too_many_matches_message(design_doc, matches)) if matches.length > AMBIGUOUS_MATCH_LIMIT

        ResolvedOffsets.new(start_offset: nil, end_offset: nil, error: ambiguous_matches_message(design_doc, visible, original_markdown, matches))
      end

      def missing_match_message(design_doc)
        "original_markdown was not found in the current rendered Markdown for #{design_doc.display_id}. Re-read the Design Doc; the text may be stale, or it may differ by whitespace or Unicode characters."
      end

      def too_many_matches_message(design_doc, matches)
        "original_markdown appears #{matches.length} times in the current rendered Markdown for #{design_doc.display_id}, which is too many to enumerate. Include more surrounding text in original_markdown to make the selection unique."
      end

      def ambiguous_matches_message(design_doc, visible, original_markdown, matches)
        entries = matches.each_with_index.map do |start, index|
          finish = start + original_markdown.length
          "Occurrence #{index + 1}: start_offset=#{start}, end_offset=#{finish}\n#{context_snippet(visible, start, finish)}"
        end

        <<~MESSAGE.strip
          original_markdown appears #{matches.length} times in the current rendered Markdown for #{design_doc.display_id}.
          #{entries.join("\n\n")}

          Retry with occurrence_index: N to pick one of these occurrences, or include more surrounding text in original_markdown to make it unique.
        MESSAGE
      end

      def context_snippet(visible, start_offset, end_offset)
        line_ranges = visible.to_enum(:scan, /^.*(?:\n|$)/).map { Regexp.last_match.begin(0)...Regexp.last_match.end(0) }
        line_index = line_ranges.index { |range| range.cover?(start_offset) || start_offset == range.end } || 0
        first_line = [ line_index - CONTEXT_LINES, 0 ].max
        last_line = [ line_index + CONTEXT_LINES, line_ranges.length - 1 ].min
        snippet_start = line_ranges[first_line].begin
        snippet_end = [ line_ranges[last_line].end, end_offset ].max

        visible[snippet_start...snippet_end].to_s.strip
      end
    end
  end
end
