module DesignDocs
  module AnchorMarkers
    POINT_PATTERN = /<!--\s*syrus:anchor\s+id="([^"]+)"\s*-->/.freeze
    RANGE_START_PATTERN = /<!--\s*syrus:range-start\s+id="([^"]+)"\s*-->/.freeze
    RANGE_END_PATTERN = /<!--\s*syrus:range-end\s+id="([^"]+)"\s*-->/.freeze
    ANY_PATTERN = /<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="[^"]+"\s*-->/.freeze

    Location = Data.define(:status, :start_offset, :end_offset, :selected_markdown, :prefix_context, :suffix_context)
    Inserted = Data.define(:markdown, :start_offset, :end_offset, :selected_markdown, :prefix_context, :suffix_context)
    Projection = Data.define(:markdown, :locations, :stale_anchors)

    LOCAL_SEARCH_RADIUS = 240
    BLOCK_PREFIX_PATTERN = /\A(?: {0,3}(?:[-+*]\s+|\d+[.)]\s+|\#{1,6}\s+)|\s*\|)/.freeze

    module_function

    def strip(markdown)
      markdown.to_s
        .gsub(/\A(?:[ \t]*#{ANY_PATTERN.source}[ \t]*\n)+/, "")
        .gsub(/\n(?:[ \t]*#{ANY_PATTERN.source}[ \t]*\n)+/, "\n")
        .gsub(ANY_PATTERN, "")
    end

    def point_marker(marker_id)
      %(<!-- syrus:anchor id="#{marker_id}" -->)
    end

    def range_start_marker(marker_id)
      %(<!-- syrus:range-start id="#{marker_id}" -->)
    end

    def range_end_marker(marker_id)
      %(<!-- syrus:range-end id="#{marker_id}" -->)
    end

    def insert(markdown:, marker_id:, start_offset:, end_offset:, anchor_kind:)
      raw = markdown.to_s
      visible = strip(raw)
      start_offset = clamp_offset(start_offset, visible.length)
      end_offset = clamp_offset(end_offset, visible.length)
      start_offset, end_offset = end_offset, start_offset if end_offset < start_offset
      raw_start_offset = raw_offset_for_visible_offset(raw, start_offset)
      raw_end_offset = raw_offset_for_visible_offset(raw, end_offset)

      if anchor_kind.to_s == "point"
        marker = block_safe_marker(visible, start_offset, point_marker(marker_id))
        marked = raw.dup.insert(raw_start_offset, marker)
      else
        marked = raw.dup
        marked.insert(raw_end_offset, block_safe_marker(visible, end_offset, range_end_marker(marker_id)))
        marked.insert(raw_start_offset, block_safe_marker(visible, start_offset, range_start_marker(marker_id)))
      end

      selected = visible[start_offset...end_offset].to_s
      Inserted.new(
        markdown: marked,
        start_offset: start_offset,
        end_offset: end_offset,
        selected_markdown: selected,
        prefix_context: visible[[ start_offset - 80, 0 ].max...start_offset].to_s,
        suffix_context: visible[end_offset...(end_offset + 80)].to_s
      )
    end

    def locate(markdown:, marker_id:, anchor_kind:)
      raw = markdown.to_s
      if anchor_kind.to_s == "point"
        matches = raw.enum_for(:scan, /<!--\s*syrus:anchor\s+id="#{Regexp.escape(marker_id)}"\s*-->/).map { Regexp.last_match.begin(0) }
        return missing_location if matches.empty?
        return duplicated_location if matches.many?

        stripped_before = logical_offset_for_marker(raw, matches.first)
        return context_location(raw, stripped_before, stripped_before)
      end

      start_matches = raw.enum_for(:scan, /<!--\s*syrus:range-start\s+id="#{Regexp.escape(marker_id)}"\s*-->/).map { Regexp.last_match }
      end_matches = raw.enum_for(:scan, /<!--\s*syrus:range-end\s+id="#{Regexp.escape(marker_id)}"\s*-->/).map { Regexp.last_match }
      return missing_location if start_matches.empty? || end_matches.empty?
      return duplicated_location if start_matches.many? || end_matches.many?

      start_match = start_matches.first
      end_match = end_matches.first
      return missing_location if end_match.begin(0) < start_match.end(0)

      start_offset = logical_offset_for_marker(raw, start_match.begin(0))
      end_offset = logical_offset_for_marker(raw, end_match.begin(0))
      return missing_location if end_offset < start_offset

      context_location(raw, start_offset, end_offset, strip(raw)[start_offset...end_offset].to_s)
    end

    def replace_range(markdown:, marker_id:, proposed_markdown:)
      raw = markdown.to_s
      location = locate(markdown: raw, marker_id: marker_id, anchor_kind: "range")
      return nil unless location.status == "active"

      unmarked = remove(markdown: raw, marker_id: marker_id, anchor_kind: "range")
      raw_start = raw_offset_for_visible_offset(unmarked, location.start_offset)
      raw_end = raw_offset_for_visible_offset(unmarked, location.end_offset)
      unmarked[0...raw_start].to_s + proposed_markdown.to_s + unmarked[raw_end..].to_s
    end

    def remove(markdown:, marker_id:, anchor_kind:)
      raw = markdown.to_s
      if anchor_kind.to_s == "point"
        return remove_marker(raw, /<!--\s*syrus:anchor\s+id="#{Regexp.escape(marker_id)}"\s*-->/)
      end

      without_start = remove_marker(raw, /<!--\s*syrus:range-start\s+id="#{Regexp.escape(marker_id)}"\s*-->/)
      remove_marker(without_start, /<!--\s*syrus:range-end\s+id="#{Regexp.escape(marker_id)}"\s*-->/)
    end

    def marker_counts(markdown)
      counts = Hash.new { |hash, marker_id| hash[marker_id] = { point: 0, range_start: 0, range_end: 0 } }
      markdown.to_s.scan(POINT_PATTERN) { |marker_id| counts[marker_id][:point] += 1 }
      markdown.to_s.scan(RANGE_START_PATTERN) { |marker_id| counts[marker_id][:range_start] += 1 }
      markdown.to_s.scan(RANGE_END_PATTERN) { |marker_id| counts[marker_id][:range_end] += 1 }
      counts
    end

    def project(markdown:, visible_markdown:, anchors:)
      raw = markdown.to_s
      next_visible = visible_markdown.to_s
      return Projection.new(markdown: next_visible, locations: {}, stale_anchors: []) unless raw.match?(ANY_PATTERN)

      locations = {}
      stale_anchors = []
      anchors.each do |anchor|
        next unless anchor.status == "active"
        unless raw.include?(anchor.marker_id)
          stale_anchors << anchor
          next
        end

        if anchor.anchor_kind.to_s == "point"
          offset = locate_point(next_visible, anchor)
          if offset
            locations[anchor.id] = [ offset, offset ]
          else
            stale_anchors << anchor
          end
        else
          range = locate_range(next_visible, anchor)
          if range
            locations[anchor.id] = range
          else
            stale_anchors << anchor
          end
        end
      end

      pending_ids = anchors.select { |anchor| anchor.suggestions.any? { |suggestion| suggestion.state == "pending" } }.map(&:id)
      overlapping_ids = overlapping_anchor_ids(locations.slice(*pending_ids))
      stale_anchors.concat(anchors.select { |anchor| overlapping_ids.include?(anchor.id) })
      stale_ids = stale_anchors.map(&:id).to_set

      # Marker placement is physical only. Offsets and selected text always refer
      # to the marker-free Markdown, so block markers stay at the beginning of
      # their lines and continue to parse as lists, headings, and tables.
      insertions = anchors.filter_map do |anchor|
        next if stale_ids.include?(anchor.id)
        range = locations[anchor.id]
        next unless range

        if anchor.anchor_kind.to_s == "point"
          [ { offset: range.first, marker: block_safe_marker(next_visible, range.first, point_marker(anchor.marker_id)), order: 0 } ]
        else
          [
            { offset: range.last, marker: block_safe_marker(next_visible, range.last, range_end_marker(anchor.marker_id)), order: 0 },
            { offset: range.first, marker: block_safe_marker(next_visible, range.first, range_start_marker(anchor.marker_id)), order: 1 }
          ]
        end
      end.flatten

      marked = insertions
        .sort_by { |insertion| [ -insertion[:offset], insertion[:order] ] }
        .each_with_object(next_visible.dup) do |insertion, marked|
          marked.insert(clamp_offset(insertion[:offset], next_visible.length), insertion[:marker])
        end
      raise "anchor projection changed visible Markdown" unless strip(marked) == next_visible

      Projection.new(markdown: marked, locations: locations.except(*stale_ids.to_a), stale_anchors: stale_anchors.uniq)
    end

    def refresh_anchor!(anchor, markdown)
      location = locate(markdown: markdown, marker_id: anchor.marker_id, anchor_kind: anchor.anchor_kind)
      anchor.update!(
        status: location.status,
        last_known_start_offset: location.start_offset || anchor.last_known_start_offset,
        last_known_end_offset: location.end_offset || anchor.last_known_end_offset,
        prefix_context: location.prefix_context || anchor.prefix_context,
        suffix_context: location.suffix_context || anchor.suffix_context
      )
      location
    end

    def missing_location
      Location.new(status: "missing", start_offset: nil, end_offset: nil, selected_markdown: nil, prefix_context: nil, suffix_context: nil)
    end

    def duplicated_location
      Location.new(status: "duplicated", start_offset: nil, end_offset: nil, selected_markdown: nil, prefix_context: nil, suffix_context: nil)
    end

    def context_location(raw, start_offset, end_offset, selected = "")
      stripped = strip(raw)
      Location.new(
        status: "active",
        start_offset: start_offset,
        end_offset: end_offset,
        selected_markdown: selected,
        prefix_context: stripped[[ start_offset - 80, 0 ].max...start_offset].to_s,
        suffix_context: stripped[end_offset...(end_offset + 80)].to_s
      )
    end

    def clamp_offset(offset, length)
      offset.to_i.clamp(0, length)
    end

    # Every occurrence of `selection` in `markdown`, by index. Offset
    # projection and suggestion creation both use this to distinguish an
    # unambiguous exact match from missing or repeated text.
    def exact_matches(markdown, selection)
      return [] if selection.blank?

      matches = []
      offset = 0
      while (index = markdown.index(selection, offset))
        matches << index
        offset = index + 1
      end
      matches
    end

    def locate_range(markdown, anchor)
      selection = anchor.selected_markdown.to_s
      matches = exact_matches(markdown, selection)
      return [ matches.first, matches.first + selection.length ] if matches.one?

      expected = anchor.last_known_start_offset || anchor.start_offset
      local = matches.select { |offset| (offset - expected.to_i).abs <= LOCAL_SEARCH_RADIUS }
      return [ local.first, local.first + selection.length ] if local.one?

      nil
    end

    def locate_point(markdown, anchor)
      expected = anchor.last_known_start_offset || anchor.start_offset
      prefix = anchor.prefix_context.to_s
      suffix = anchor.suffix_context.to_s
      candidates = (0..markdown.length).select do |offset|
        (offset - expected.to_i).abs <= LOCAL_SEARCH_RADIUS &&
          (prefix.blank? || markdown[0...offset].to_s.end_with?(prefix)) &&
          (suffix.blank? || markdown[offset..].to_s.start_with?(suffix))
      end
      candidates.one? ? candidates.first : nil
    end

    def overlapping_anchor_ids(locations)
      locations.to_a.combination(2).each_with_object(Set.new) do |((left_id, left), (right_id, right)), ids|
        left, right = right, left if right.first < left.first
        next if left.last <= right.first

        ids << left_id << right_id
      end
    end

    def block_safe_marker(markdown, offset, marker)
      value = clamp_offset(offset, markdown.length)
      line_start = value.zero? ? 0 : (markdown.rindex("\n", value - 1)&.+(1) || 0)
      return marker unless value == line_start

      prefix = BLOCK_PREFIX_PATTERN.match(markdown[line_start..].to_s)&.[](0)
      # A marker-only line immediately before the block preserves CommonMark
      # parsing. `strip` consumes that synthetic line, so visible offsets and
      # the user's exact Markdown remain unchanged.
      prefix ? "#{marker}\n" : marker
    end

    def logical_offset_for_marker(raw, raw_offset)
      strip(raw[0...raw_offset]).length
    end

    def remove_marker(raw, pattern)
      raw
        .gsub(/\A[ \t]*#{pattern.source}[ \t]*\n/, "")
        .gsub(/\n[ \t]*#{pattern.source}[ \t]*\n/, "\n")
        .gsub(pattern, "")
    end

    def raw_offset_for_visible_offset(markdown, visible_offset)
      raw_index = 0
      visible_index = 0
      raw = markdown.to_s

      while raw_index < raw.length && visible_index < visible_offset
        marker = ANY_PATTERN.match(raw, raw_index)
        if marker&.begin(0) == raw_index
          raw_index = marker.end(0)
          raw_index += 1 if (marker.begin(0).zero? || raw[marker.begin(0) - 1] == "\n") && raw[raw_index] == "\n"
        else
          raw_index += 1
          visible_index += 1
        end
      end

      raw_index
    end
  end
end
