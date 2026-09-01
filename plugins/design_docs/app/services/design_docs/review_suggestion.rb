module DesignDocs
  class ReviewSuggestion
    Result = Data.define(:design_doc, :suggestion, :version, :applied)

    def self.accept(suggestion:, user:)
      new(suggestion: suggestion, user: user, decision: "accept").call
    end

    def self.reject(suggestion:, user:)
      new(suggestion: suggestion, user: user, decision: "reject").call
    end

    def initialize(suggestion:, user:, decision:)
      @suggestion = suggestion
      @user = user
      @decision = decision
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).review?

      DesignDoc.transaction do
        design_doc.lock!
        suggestion.lock!
        raise ActiveRecord::RecordInvalid.new(suggestion) unless suggestion.state == "pending"

        return reject if decision == "reject"

        accept
      end
    end

    private

    attr_reader :suggestion, :user, :decision

    def design_doc
      suggestion.design_doc
    end

    def reject
      suggestion.update!(state: "rejected", reviewed_at: Time.current, reviewed_by_user: user)
      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: nil, applied: false)
    end

    def accept
      anchor = suggestion.anchor
      return mark_conflict!("Suggestions can only be accepted for range anchors.") unless anchor.range?

      location = AnchorMarkers.refresh_anchor!(anchor, design_doc.markdown)
      return accept_unmarked_autosave_range(anchor) if location.status == "missing" && autosave_suggestion?
      return mark_conflict!("Anchor marker is #{location.status}.") if location.status.in?(%w[missing duplicated])
      return mark_stale!(location.selected_markdown.to_s) unless location.selected_markdown.to_s == suggestion.original_markdown.to_s

      next_markdown = AnchorMarkers.replace_range(
        markdown: design_doc.markdown,
        marker_id: anchor.marker_id,
        proposed_markdown: suggestion.proposed_markdown_value
      )
      return mark_conflict!("Anchor markers could not be re-applied.") if next_markdown.blank?

      design_doc.update!(markdown: next_markdown)
      version = design_doc.versions.create!(
        markdown: design_doc.markdown,
        version_number: next_version_number,
        actor_kind: "user",
        actor_user: user,
        change_summary: suggestion.change_summary.presence || "Accept design doc suggestion"
      )
      design_doc.update!(current_version: version)
      suggestion.update!(state: "accepted", reviewed_at: Time.current, reviewed_by_user: user)
      AnchorMarkers.refresh_anchor!(anchor, design_doc.markdown)

      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: version, applied: true)
    end

    def accept_unmarked_autosave_range(anchor)
      markdown = AnchorMarkers.strip(design_doc.markdown)
      start_offset = anchor.last_known_start_offset || anchor.start_offset
      end_offset = anchor.last_known_end_offset || anchor.end_offset
      current_text = markdown[start_offset...end_offset].to_s
      return mark_stale!(current_text) unless current_text == suggestion.original_markdown.to_s

      design_doc.update!(markdown: markdown[0...start_offset].to_s + suggestion.proposed_markdown_value + markdown[end_offset..].to_s)
      version = design_doc.versions.create!(
        markdown: design_doc.markdown,
        version_number: next_version_number,
        actor_kind: "user",
        actor_user: user,
        change_summary: suggestion.change_summary.presence || "Accept design doc suggestion"
      )
      design_doc.update!(current_version: version)
      anchor.update!(status: "active", last_known_end_offset: start_offset + suggestion.proposed_markdown_value.length)
      suggestion.update!(state: "accepted", reviewed_at: Time.current, reviewed_by_user: user)

      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: version, applied: true)
    end

    def autosave_suggestion?
      ActiveModel::Type::Boolean.new.cast(suggestion.provenance&.fetch("autosave", false))
    end

    def mark_conflict!(reason)
      suggestion.update!(state: "conflict", reviewed_at: Time.current, reviewed_by_user: user, conflict_reason: reason)
      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: nil, applied: false)
    end

    def mark_stale!(current_text)
      suggestion.anchor.update!(status: "stale")
      suggestion.update!(
        state: "stale",
        reviewed_at: Time.current,
        reviewed_by_user: user,
        conflict_reason: "Original text no longer matches anchor. Current text: #{current_text.inspect}"
      )
      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: nil, applied: false)
    end

    def next_version_number
      design_doc.versions.maximum(:version_number).to_i + 1
    end
  end
end
