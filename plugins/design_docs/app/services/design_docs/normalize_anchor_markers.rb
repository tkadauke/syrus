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
      refresh_marked_anchors!
      assert_marker_pairs!
      assert_no_pending_suggestion_overlaps!

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

    def assert_marker_pairs!
      AnchorMarkers.marker_counts(design_doc.markdown).each do |marker_id, counts|
        point_count = counts[:point]
        start_count = counts[:range_start]
        end_count = counts[:range_end]

        if point_count > 1 || start_count > 1 || end_count > 1
          raise InvariantError, "Duplicate design doc anchor marker #{marker_id.inspect}."
        end

        if point_count.positive? && (start_count.positive? || end_count.positive?)
          raise InvariantError, "Design doc anchor marker #{marker_id.inspect} mixes point and range markers."
        end

        next if point_count == 1
        next if start_count == 1 && end_count == 1

        raise InvariantError, "Design doc anchor marker #{marker_id.inspect} has an orphan range marker."
      end
    end

    def assert_no_pending_suggestion_overlaps!
      ranges = pending_suggestion_ranges
      ranges.each_cons(2) do |left, right|
        next unless left[:start] < right[:end] && right[:start] < left[:end]

        raise InvariantError, "Pending design doc suggestions ##{left[:suggestion_id]} and ##{right[:suggestion_id]} overlap."
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
          suggestion_id: suggestion.id,
          start: location.start_offset,
          end: location.end_offset
        }
      end.sort_by { |range| [ range[:start], range[:end], range[:suggestion_id] ] }
    end
  end
end
