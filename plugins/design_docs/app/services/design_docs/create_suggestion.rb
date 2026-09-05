module DesignDocs
  class CreateSuggestion
    Result = Data.define(:design_doc, :anchor, :suggestion, :version)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, user:, attributes:, actor_kind: "user")
      @design_doc = design_doc
      @user = user
      @attributes = attributes
      @actor_kind = actor_kind.to_s.presence || "user"
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).suggest?

      DesignDoc.transaction do
        base_version = design_doc.current_version
        visible = AnchorMarkers.strip(design_doc.markdown)
        start_offset, end_offset = normalized_offsets(visible.length)
        if autosave? || full_document_suggestion?
          draft = existing_autosave_suggestion
          if draft
            ensure_suggestion_thread!(draft)
            draft.update!(
              suggested_markdown: proposed_markdown,
              proposed_markdown: proposed_markdown,
              change_summary: attributes[:change_summary].presence,
              agent_run: agent_run,
              provenance: draft.provenance.merge(
                "autosave" => autosave?,
                "autosaved_at" => Time.current.iso8601,
                "design_doc_agent_run_id" => attributes[:design_doc_agent_run_id].presence,
                "triggering_comment_id" => attributes[:triggering_comment_id].presence
              ).compact,
              render_mode: render_mode(visible[start_offset...end_offset].to_s, proposed_markdown)
            )

            return Result.new(design_doc: design_doc.reload, anchor: draft.anchor, suggestion: draft, version: nil)
          end
        end

        validate_range!(visible, start_offset, end_offset) unless autosave?
        validate_pending_overlap!(start_offset, end_offset) unless full_document_suggestion?
        return create_autosave_suggestion(base_version) if autosave?

        anchor_result = CreateAnchor.call(
          design_doc: design_doc,
          user: user,
          attributes: anchor_attributes,
          actor_kind: actor_kind
        )
        suggestion = design_doc.suggestions.create!(
          anchor: anchor_result.anchor,
          thread: suggestion_thread(anchor_result.anchor),
          base_version: base_version,
          suggested_by_kind: actor_kind,
          suggested_by_user: actor_kind == "user" ? user : nil,
          original_markdown: original_markdown(anchor_result.anchor),
          suggested_markdown: proposed_markdown,
          proposed_markdown: proposed_markdown,
          change_type: attributes[:change_type].presence || "replace",
          render_mode: render_mode(original_markdown(anchor_result.anchor), proposed_markdown),
          change_summary: attributes[:change_summary].presence,
          agent_run: agent_run,
          provenance: provenance(base_version)
        )

        Result.new(design_doc: design_doc.reload, anchor: anchor_result.anchor, suggestion: suggestion, version: anchor_result.version)
      end
    end

    private

    BLOCK_MARKER_PATTERN = /\A\s{0,3}(\#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?|```|~~~)/

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def create_autosave_suggestion(base_version)
      visible = AnchorMarkers.strip(design_doc.markdown)
      start_offset, end_offset = normalized_offsets(visible.length)
      validate_pending_overlap!(start_offset, end_offset) unless full_document_suggestion?
      anchor = create_autosave_anchor(base_version)
      suggestion = design_doc.suggestions.create!(
        anchor: anchor,
        thread: suggestion_thread(anchor),
        base_version: base_version,
        suggested_by_kind: actor_kind,
        suggested_by_user: actor_kind == "user" ? user : nil,
        original_markdown: original_markdown(anchor),
        suggested_markdown: proposed_markdown,
        proposed_markdown: proposed_markdown,
        change_type: attributes[:change_type].presence || "replace",
        render_mode: render_mode(original_markdown(anchor), proposed_markdown),
        change_summary: attributes[:change_summary].presence,
        agent_run: agent_run,
        provenance: provenance(base_version)
      )

      Result.new(design_doc: design_doc.reload, anchor: anchor, suggestion: suggestion, version: nil)
    end

    def create_autosave_anchor(base_version)
      visible = AnchorMarkers.strip(design_doc.markdown)
      start_offset, end_offset = normalized_offsets(visible.length)
      marker_id = SecureRandom.uuid

      design_doc.anchors.create!(
        marker_id: marker_id,
        anchor_key: marker_id,
        anchor_kind: "range",
        design_doc_version: base_version,
        start_offset: start_offset,
        end_offset: end_offset,
        last_known_start_offset: start_offset,
        last_known_end_offset: end_offset,
        selected_markdown: attributes[:selected_markdown].presence || attributes[:selected_text].presence || visible[start_offset...end_offset].to_s,
        selected_text: attributes[:selected_text].presence || attributes[:selected_markdown].presence || visible[start_offset...end_offset].to_s,
        prefix_context: visible[[ start_offset - 80, 0 ].max...start_offset].to_s,
        suffix_context: visible[end_offset...(end_offset + 80)].to_s,
        status: "active"
      )
    end

    def anchor_attributes
      attributes.slice(:start_offset, :end_offset, :selected_markdown, :selected_text, :anchor_kind)
        .merge(change_summary: "Add suggestion anchor")
    end

    def suggestion_thread(anchor)
      return design_doc.threads.find(attributes[:thread_id]) if attributes[:thread_id].present?

      design_doc.threads.create!(
        anchor: anchor,
        opened_by_user: actor_kind == "user" ? user : nil
      )
    end

    def ensure_suggestion_thread!(suggestion)
      return if suggestion.thread

      suggestion.update!(thread: suggestion_thread(suggestion.anchor))
    end

    def original_markdown(anchor)
      candidate = attributes[:original_markdown].presence || attributes[:selected_markdown].presence || attributes[:selected_text].presence
      return candidate if candidate.blank? || candidate == anchor.selected_markdown

      anchor.selected_markdown.to_s
    end

    def proposed_markdown
      attributes[:proposed_markdown].presence || attributes[:suggested_markdown].presence || attributes[:markdown].to_s
    end

    def provenance(base_version)
      {
        "suggested_at" => Time.current.iso8601,
        "autosave" => autosave?,
        "suggested_by_user_id" => actor_kind == "user" ? user&.id : nil,
        "actor_kind" => actor_kind,
        "base_version_id" => base_version&.id,
        "run_id" => attributes[:run_id].presence,
        "workflow_id" => attributes[:workflow_id].presence,
        "chat_message_id" => attributes[:chat_message_id].presence,
        "design_doc_agent_run_id" => attributes[:design_doc_agent_run_id].presence,
        "triggering_comment_id" => attributes[:triggering_comment_id].presence
      }.compact
    end

    def agent_run
      return nil if attributes[:design_doc_agent_run_id].blank?

      @agent_run ||= DesignDocs::DesignDocAgentRun.find(attributes[:design_doc_agent_run_id])
    end

    def autosave?
      ActiveModel::Type::Boolean.new.cast(attributes[:autosave])
    end

    def full_document_suggestion?
      start_offset, end_offset = normalized_offsets(AnchorMarkers.strip(design_doc.markdown).length)
      start_offset.zero? && end_offset == AnchorMarkers.strip(design_doc.markdown).length
    end

    def normalized_offsets(length)
      start_offset = attributes[:start_offset].presence&.to_i || 0
      end_offset = attributes[:end_offset].presence&.to_i || length
      start_offset = start_offset.clamp(0, length)
      end_offset = end_offset.clamp(0, length)
      return [ end_offset, start_offset ] if end_offset < start_offset

      [ start_offset, end_offset ]
    end

    def existing_autosave_suggestion
      candidates = design_doc.suggestions
        .where(state: "pending", suggested_by_kind: actor_kind)
      candidates = actor_kind == "user" ? candidates.where(suggested_by_user: user) : candidates.where(suggested_by_user_id: nil)
      candidates.order(created_at: :desc, id: :desc).detect { |suggestion| ActiveModel::Type::Boolean.new.cast(suggestion.provenance&.fetch("autosave", false)) }
    end

    def validate_range!(visible, start_offset, end_offset)
      return if start_offset == end_offset
      return if block_boundary?(visible, start_offset) && block_boundary?(visible, end_offset)

      selected = visible[start_offset...end_offset].to_s
      return unless selected.match?(BLOCK_MARKER_PATTERN) || cuts_block_marker?(visible, start_offset) || cuts_block_marker?(visible, end_offset)

      raise_invalid_suggestion!("Suggestions cannot select only part of Markdown block syntax. Select the whole heading, list item, quote, or code fence block.")
    end

    def validate_pending_overlap!(start_offset, end_offset)
      return if start_offset == end_offset

      overlapping = design_doc.suggestions.includes(:anchor).where(state: "pending").detect do |suggestion|
        anchor = suggestion.anchor
        next false unless anchor&.range?

        other_start = anchor.last_known_start_offset || anchor.start_offset
        other_end = anchor.last_known_end_offset || anchor.end_offset
        next false if other_start.nil? || other_end.nil?

        start_offset < other_end && end_offset > other_start
      end
      return unless overlapping

      raise_invalid_suggestion!("Suggestion overlaps pending suggestion ##{overlapping.id}. Review the existing thread before creating another active suggestion for the same range.")
    end

    def render_mode(original, proposed)
      inline_safe?(original) && inline_safe?(proposed) ? "inline" : "block"
    end

    def inline_safe?(markdown)
      text = markdown.to_s
      return false if text.include?("\n")

      !text.match?(BLOCK_MARKER_PATTERN)
    end

    def cuts_block_marker?(visible, offset)
      line_start = visible.rindex("\n", [ offset - 1, 0 ].max)&.+(1) || 0
      line_end = visible.index("\n", offset) || visible.length
      line = visible[line_start...line_end].to_s
      marker = BLOCK_MARKER_PATTERN.match(line)
      return false unless marker

      marker_end = line_start + marker[0].length
      offset > line_start && offset < marker_end
    end

    def block_boundary?(visible, offset)
      return true if offset.zero? || offset == visible.length
      return true if visible[offset - 1] == "\n" && (visible[offset] == "\n" || visible[offset].nil?)
      return true if visible[offset - 1] == "\n" && line_starts_with_block_marker?(visible, offset)
      return true if visible[offset] == "\n" && (visible[offset + 1] == "\n" || visible[offset + 1].nil?)
      return true if visible[offset] == "\n" && line_starts_with_block_marker?(visible, offset + 1)

      false
    end

    def line_starts_with_block_marker?(visible, offset)
      line_end = visible.index("\n", offset) || visible.length
      visible[offset...line_end].to_s.match?(BLOCK_MARKER_PATTERN)
    end

    def raise_invalid_suggestion!(message)
      suggestion = design_doc.suggestions.build
      suggestion.errors.add(:base, message)
      raise ActiveRecord::RecordInvalid.new(suggestion)
    end
  end
end
