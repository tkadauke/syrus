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

      old_markdown = design_doc.markdown
      location = AnchorMarkers.refresh_anchor!(anchor, design_doc.markdown)
      return accept_unmarked_autosave_range(anchor, old_markdown) if location.status == "missing" && autosave_suggestion?
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
      reconcile_unrelated_anchors!(old_markdown: old_markdown, version: version, accepted_anchor: anchor)

      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: version, applied: true)
    end

    def accept_unmarked_autosave_range(anchor, old_markdown)
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
      reconcile_unrelated_anchors!(old_markdown: old_markdown, version: version, accepted_anchor: anchor)

      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: version, applied: true)
    end

    # Accepting a suggestion can overwrite raw markdown that other anchors'
    # hidden markers were sitting in (a full-document suggestion is the
    # extreme case: its replaced range is the entire document). Anything that
    # was active before and lost its marker gets re-projected onto the new
    # text when the exact same excerpt still exists exactly once, otherwise
    # it's marked stale immediately instead of quietly drifting to the wrong
    # offsets. Anchors whose marker survived untouched still get their cached
    # offsets refreshed, since the surrounding text length may have changed.
    def reconcile_unrelated_anchors!(old_markdown:, version:, accepted_anchor:)
      design_doc.anchors.where(status: "active").where.not(id: accepted_anchor.id).find_each do |candidate|
        before = AnchorMarkers.locate(markdown: old_markdown, marker_id: candidate.marker_id, anchor_kind: candidate.anchor_kind)
        next unless before.status == "active"

        after = AnchorMarkers.locate(markdown: design_doc.markdown, marker_id: candidate.marker_id, anchor_kind: candidate.anchor_kind)
        if after.status == "active"
          candidate.update!(
            last_known_start_offset: after.start_offset,
            last_known_end_offset: after.end_offset,
            prefix_context: after.prefix_context,
            suffix_context: after.suffix_context
          )
          next
        end

        reproject_or_mark_stale!(candidate, version, after)
      end
    end

    # `after.status == "duplicated"` means the candidate's marker id already
    # appears more than once in the current markdown; inserting yet another
    # occurrence via AnchorMarkers.insert would not resolve that; it would
    # just add a third one. Only "missing" (the marker is genuinely gone) is
    # eligible for re-projection -- anything else goes straight to stale.
    #
    # Point anchors always have an empty `selected_markdown` (they mark a
    # single position, not a text range), so there is nothing to search for
    # and they always fall through to stale here -- there is no such thing
    # as a safe re-projection for a point anchor once its marker is gone.
    def reproject_or_mark_stale!(candidate, version, after)
      return mark_unrelated_anchor_stale!(candidate, version) unless after.status == "missing"

      selected = candidate.selected_markdown.to_s
      matches = AnchorMarkers.exact_matches(AnchorMarkers.strip(design_doc.markdown), selected)

      return mark_unrelated_anchor_stale!(candidate, version) unless matches.one?

      inserted = AnchorMarkers.insert(
        markdown: design_doc.markdown,
        marker_id: candidate.marker_id,
        start_offset: matches.first,
        end_offset: matches.first + selected.length,
        anchor_kind: candidate.anchor_kind
      )
      design_doc.update!(markdown: inserted.markdown)
      candidate.update!(
        status: "active",
        last_known_start_offset: inserted.start_offset,
        last_known_end_offset: inserted.end_offset,
        prefix_context: inserted.prefix_context,
        suffix_context: inserted.suffix_context
      )
    end

    def mark_unrelated_anchor_stale!(candidate, version)
      candidate.update!(status: "stale", stale_as_of_version: version)
      candidate.suggestions.where(state: "pending").find_each do |pending|
        pending.update!(
          state: "stale",
          reviewed_at: Time.current,
          reviewed_by_user: user,
          conflict_reason: "Anchor marker was overwritten while accepting suggestion ##{suggestion.id}."
        )
      end
    end

    def autosave_suggestion?
      ActiveModel::Type::Boolean.new.cast(suggestion.provenance&.fetch("autosave", false))
    end

    def mark_conflict!(reason)
      suggestion.update!(state: "conflict", reviewed_at: Time.current, reviewed_by_user: user, conflict_reason: reason)
      Result.new(design_doc: design_doc.reload, suggestion: suggestion, version: nil, applied: false)
    end

    def mark_stale!(current_text)
      # No new version is created on this path (the suggestion is rejected
      # outright, not applied), so the design doc's current version is the
      # closest available "as of" marker for when the anchor stopped being
      # trustworthy -- same invariant `mark_unrelated_anchor_stale!` keeps
      # for the reconciliation path, just anchored to the existing version
      # instead of a newly created one.
      suggestion.anchor.update!(status: "stale", stale_as_of_version: design_doc.current_version)
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
