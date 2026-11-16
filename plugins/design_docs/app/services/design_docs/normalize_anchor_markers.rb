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

        anchor.update!(status: location.status)
      end
    end

    def repair_invalid_marker_sets!
      AnchorMarkers.marker_counts(design_doc.markdown).each do |marker_id, counts|
        point_count = counts[:point]
        start_count = counts[:range_start]
        end_count = counts[:range_end]

        reason = if point_count > 1 || start_count > 1 || end_count > 1
          "Anchor marker #{marker_id.inspect} was duplicated."
        elsif point_count.positive? && (start_count.positive? || end_count.positive?)
          "Anchor marker #{marker_id.inspect} mixed point and range markers."
        elsif point_count != 1 && !(start_count == 1 && end_count == 1)
          "Anchor marker #{marker_id.inspect} had an orphan range marker."
        end
        repair_marker_set!(marker_id, reason) if reason
      end
    end

    def repair_pending_suggestion_overlaps!
      ranges = pending_suggestion_ranges
      collisions = ranges.combination(2).select do |left, right|
        left[:start] < right[:end] && right[:start] < left[:end]
      end
      collisions.flatten.uniq { |range| range[:suggestion_id] }.each do |range|
        suggestion = range[:suggestion]
        other_ids = collisions.filter_map do |left, right|
          next unless left[:suggestion_id] == suggestion.id || right[:suggestion_id] == suggestion.id

          left[:suggestion_id] == suggestion.id ? right[:suggestion_id] : left[:suggestion_id]
        end.uniq
        mark_anchor_and_pending_suggestions_stale!(
          suggestion.anchor,
          "Pending suggestion ##{suggestion.id} overlapped pending suggestion#{'s' if other_ids.many?} #{other_ids.map { |id| "##{id}" }.to_sentence}."
        )
      end
    end

    def repair_marker_set!(marker_id, reason)
      design_doc.anchors.where(marker_id: marker_id).find_each do |anchor|
        mark_anchor_and_pending_suggestions_stale!(anchor, reason)
      end
      remove_all_marker_fragments!(marker_id)
    end

    def mark_anchor_and_pending_suggestions_stale!(anchor, reason)
      anchor.update!(status: "stale", stale_as_of_version: design_doc.current_version)
      anchor.suggestions.where(state: "pending").find_each do |pending|
        pending.update!(state: "stale", reviewed_at: Time.current, conflict_reason: reason)
      end
      remove_all_marker_fragments!(anchor.marker_id)
    end

    def remove_all_marker_fragments!(marker_id)
      escaped = Regexp.escape(marker_id)
      cleaned = design_doc.markdown.to_s.gsub(/<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="#{escaped}"\s*-->/, "")
      design_doc.update!(markdown: cleaned) if cleaned != design_doc.markdown
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
          suggestion: suggestion,
          suggestion_id: suggestion.id,
          start: location.start_offset,
          end: location.end_offset
        }
      end.sort_by { |range| [ range[:start], range[:end], range[:suggestion_id] ] }
    end
  end
end
