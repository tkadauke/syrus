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
      repair_malformed_marker_sets!
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

        escaped_id = Regexp.escape(anchor.marker_id)
        next_markdown = next_markdown.gsub(
          /<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="#{escaped_id}"\s*-->/,
          ""
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

    def repair_malformed_marker_sets!
      AnchorMarkers.marker_counts(design_doc.markdown).each do |marker_id, counts|
        point_count = counts[:point]
        start_count = counts[:range_start]
        end_count = counts[:range_end]

        if point_count > 1 || start_count > 1 || end_count > 1
          stale_marker_set!(marker_id, "Anchor marker was duplicated.")
        elsif point_count.positive? && (start_count.positive? || end_count.positive?)
          stale_marker_set!(marker_id, "Anchor marker mixed point and range markers.")
        elsif point_count != 1 && (start_count != 1 || end_count != 1)
          stale_marker_set!(marker_id, "Anchor marker had an orphan range marker.")
        end
      end
    end

    def repair_pending_suggestion_overlaps!
      ranges = pending_suggestion_ranges
      collisions = ranges.combination(2).select do |left, right|
        left[:start] < right[:end] && right[:start] < left[:end]
      end
      return if collisions.empty?

      reasons = Hash.new { |hash, suggestion_id| hash[suggestion_id] = [] }
      collisions.each do |left, right|
        reasons[left[:suggestion_id]] << right[:suggestion_id]
        reasons[right[:suggestion_id]] << left[:suggestion_id]
      end
      reasons.each do |suggestion_id, other_ids|
        suggestion = design_doc.suggestions.includes(:anchor).find(suggestion_id)
        names = other_ids.uniq.sort.map { |id| "##{id}" }.to_sentence
        stale_anchor!(suggestion.anchor, "Pending suggestion overlaps #{names}.")
      end
    end

    def stale_marker_set!(marker_id, reason)
      anchors = design_doc.anchors.where(marker_id: marker_id)
      anchors.find_each { |anchor| stale_anchor!(anchor, reason) }
      remove_all_marker_fragments!(marker_id)
    end

    def stale_anchor!(anchor, reason)
      return unless anchor

      anchor.update!(status: "stale", stale_as_of_version: design_doc.current_version)
      anchor.suggestions.where(state: "pending").find_each do |suggestion|
        suggestion.update!(state: "stale", conflict_reason: reason)
      end
      remove_all_marker_fragments!(anchor.marker_id)
    end

    def remove_all_marker_fragments!(marker_id)
      escaped_id = Regexp.escape(marker_id)
      cleaned = design_doc.markdown.to_s.gsub(
        /<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="#{escaped_id}"\s*-->/,
        ""
      )
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
          suggestion_id: suggestion.id,
          start: location.start_offset,
          end: location.end_offset
        }
      end.sort_by { |range| [ range[:start], range[:end], range[:suggestion_id] ] }
    end
  end
end
