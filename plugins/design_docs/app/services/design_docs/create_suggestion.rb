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
        if autosave? || full_document_suggestion?
          draft = existing_autosave_suggestion
          if draft
            draft.update!(
              suggested_markdown: proposed_markdown,
              proposed_markdown: proposed_markdown,
              change_summary: attributes[:change_summary].presence,
              provenance: draft.provenance.merge(
                "autosave" => autosave?,
                "autosaved_at" => Time.current.iso8601
              )
            )

            return Result.new(design_doc: design_doc.reload, anchor: draft.anchor, suggestion: draft, version: nil)
          end
        end

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
          change_summary: attributes[:change_summary].presence,
          provenance: provenance(base_version)
        )

        Result.new(design_doc: design_doc.reload, anchor: anchor_result.anchor, suggestion: suggestion, version: anchor_result.version)
      end
    end

    private

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def create_autosave_suggestion(base_version)
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
        change_summary: attributes[:change_summary].presence,
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
      return nil if attributes[:thread_id].blank?

      design_doc.threads.find(attributes[:thread_id])
    end

    def original_markdown(anchor)
      attributes[:original_markdown].presence || attributes[:selected_markdown].presence || attributes[:selected_text].presence || anchor.selected_text.to_s
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
        "chat_message_id" => attributes[:chat_message_id].presence
      }.compact
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
  end
end
