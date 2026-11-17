module DesignDocs
  class NormalizeAnchorMarkers
    InvariantError = Class.new(StandardError)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:)
      @design_doc = design_doc
    end

    def call
      remove_reviewed_suggestion_markers!
      repair_invalid_marker_sets!
      refresh_marked_anchors!
      repair_pending_suggestion_overlaps!

      design_doc
    end

    private

    attr_reader :design_doc

    def remove_reviewed_suggestion_markers!
      next_markdown = design_doc.markdown.to_s
      design_doc.suggestions.includes(:anchor).where.not(state: "pending").find_each do |suggestion|
        anchor = suggestion.anchor
        next unless anchor

        next_markdown = AnchorMarkers.remove(
          markdown: next_markdown,
          marker_id: anchor.marker_id,
          anchor_kind: anchor.anchor_kind
        )
      end

      design_doc.update!(markdown: next_markdown) if next_markdown != design_doc.markdown
    end

    def refresh_marked_anchors!
      design_doc.anchors.where(status: "active").find_each do |anchor|
        location = AnchorMarkers.locate(
          markdown: design_doc.markdown,
          marker_id: anchor.marker_id,
          anchor_kind: anchor.anchor_kind
        )
        next if location.status == "active"
        next if location.status == "missing" && unmarked_autosave_anchor?(anchor)

        stale_anchor_and_suggestions!(anchor, "Anchor marker is #{location.status}.")
        remove_marker_fragments!(anchor.marker_id)
      end
    end

    def repair_invalid_marker_sets!
      AnchorMarkers.marker_counts(design_doc.markdown).each do |marker_capture, counts|
        marker_id = Array(marker_capture).first
        point_count = counts[:point]
        start_count = counts[:range_start]
        end_count = counts[:range_end]

        reason = if point_count > 1 || start_count > 1 || end_count > 1
          "Anchor marker is duplicated."
        elsif point_count.positive? && (start_count.positive? || end_count.positive?)
          "Anchor marker mixes point and range markers."
        elsif point_count != 1 && (start_count != 1 || end_count != 1)
          "Anchor has an orphan range marker."
        end
        next unless reason

        stale_anchor_and_suggestions!(design_doc.anchors.find_by(marker_id: marker_id), reason)
        remove_marker_fragments!(marker_id)
      end
    end

    def repair_pending_suggestion_overlaps!
      ranges = pending_suggestion_ranges
      collisions = ranges.combination(2).select do |left, right|
        left[:start] < right[:end] && right[:start] < left[:end]
      end
      collisions.flatten.uniq { |range| range[:suggestion_id] }.each do |range|
        others = collisions.filter_map do |left, right|
          next unless left[:suggestion_id] == range[:suggestion_id] || right[:suggestion_id] == range[:suggestion_id]

          left[:suggestion_id] == range[:suggestion_id] ? right[:suggestion_id] : left[:suggestion_id]
        end.uniq.sort
        stale_anchor_and_suggestions!(range[:anchor], "Anchor overlaps pending suggestion#{'s' if others.many?} #{others.map { |id| "##{id}" }.join(', ')}.")
        remove_marker_fragments!(range[:anchor].marker_id)
      end
    end

    def pending_suggestion_ranges
      design_doc.suggestions.includes(:anchor).where(state: "pending").filter_map do |suggestion|
        anchor = suggestion.anchor
        next unless anchor&.range?

        location = AnchorMarkers.locate(
          markdown: design_doc.markdown,
          marker_id: anchor.marker_id,
          anchor_kind: anchor.anchor_kind
        )
        next unless location.status == "active"

        {
          anchor: anchor,
          suggestion_id: suggestion.id,
          start: location.start_offset,
          end: location.end_offset
        }
      end.sort_by { |range| [ range[:start], range[:end], range[:suggestion_id] ] }
    end

    def stale_anchor_and_suggestions!(anchor, reason)
      return unless anchor

      anchor.update!(status: "stale", stale_as_of_version: design_doc.current_version)
      anchor.suggestions.where(state: "pending").find_each do |suggestion|
        suggestion.update!(state: "stale", reviewed_at: Time.current, conflict_reason: reason)
      end
    end

    def unmarked_autosave_anchor?(anchor)
      anchor.suggestions.where(state: "pending").any? do |suggestion|
        ActiveModel::Type::Boolean.new.cast(suggestion.provenance&.fetch("autosave", false))
      end
    end

    def remove_marker_fragments!(marker_id)
      cleaned = AnchorMarkers.remove(markdown: design_doc.markdown, marker_id: marker_id, anchor_kind: "point")
      cleaned = AnchorMarkers.remove(markdown: cleaned, marker_id: marker_id, anchor_kind: "range")
      design_doc.update!(markdown: cleaned) if cleaned != design_doc.markdown
    end
  end
end
