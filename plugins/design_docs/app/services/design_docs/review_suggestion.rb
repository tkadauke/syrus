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
      location = AnchorMarkers.refresh_anchor!(anchor, design_doc.markdown)
      return mark_conflict!("Anchor marker is #{location.status}.") if location.status.in?(%w[missing duplicated])
      return mark_conflict!("Suggestions can only be accepted for range anchors.") unless anchor.range?
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
