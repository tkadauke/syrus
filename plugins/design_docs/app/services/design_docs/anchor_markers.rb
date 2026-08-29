module DesignDocs
  module AnchorMarkers
    POINT_PATTERN = /<!--\s*syrus:anchor\s+id="([^"]+)"\s*-->/.freeze
    RANGE_START_PATTERN = /<!--\s*syrus:range-start\s+id="([^"]+)"\s*-->/.freeze
    RANGE_END_PATTERN = /<!--\s*syrus:range-end\s+id="([^"]+)"\s*-->/.freeze
    ANY_PATTERN = /<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="[^"]+"\s*-->/.freeze

    Location = Data.define(:status, :start_offset, :end_offset, :selected_markdown, :prefix_context, :suffix_context)
    Inserted = Data.define(:markdown, :start_offset, :end_offset, :selected_markdown, :prefix_context, :suffix_context)

    module_function

    def strip(markdown)
      markdown.to_s.gsub(ANY_PATTERN, "")
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
        marker = point_marker(marker_id)
        marked = raw.dup.insert(raw_start_offset, marker)
      else
        marked = raw.dup
        marked.insert(raw_end_offset, range_end_marker(marker_id))
        marked.insert(raw_start_offset, range_start_marker(marker_id))
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

        stripped_before = strip(raw[0...matches.first]).length
        return context_location(raw, stripped_before, stripped_before)
      end

      start_matches = raw.enum_for(:scan, /<!--\s*syrus:range-start\s+id="#{Regexp.escape(marker_id)}"\s*-->/).map { Regexp.last_match }
      end_matches = raw.enum_for(:scan, /<!--\s*syrus:range-end\s+id="#{Regexp.escape(marker_id)}"\s*-->/).map { Regexp.last_match }
      return missing_location if start_matches.empty? || end_matches.empty?
      return duplicated_location if start_matches.many? || end_matches.many?

      start_match = start_matches.first
      end_match = end_matches.first
      return missing_location if end_match.begin(0) < start_match.end(0)

      selected = strip(raw[start_match.end(0)...end_match.begin(0)])
      start_offset = strip(raw[0...start_match.begin(0)]).length
      context_location(raw, start_offset, start_offset + selected.length, selected)
    end

    def replace_range(markdown:, marker_id:, proposed_markdown:)
      raw = markdown.to_s
      start_regex = /<!--\s*syrus:range-start\s+id="#{Regexp.escape(marker_id)}"\s*-->/
      end_regex = /<!--\s*syrus:range-end\s+id="#{Regexp.escape(marker_id)}"\s*-->/
      start_match = start_regex.match(raw)
      end_match = end_regex.match(raw)
      return nil unless start_match && end_match && end_match.begin(0) >= start_match.end(0)

      raw[0...start_match.end(0)] + proposed_markdown.to_s + raw[end_match.begin(0)..]
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

    def raw_offset_for_visible_offset(markdown, visible_offset)
      raw_index = 0
      visible_index = 0
      raw = markdown.to_s

      while raw_index < raw.length && visible_index < visible_offset
        marker = ANY_PATTERN.match(raw, raw_index)
        if marker&.begin(0) == raw_index
          raw_index = marker.end(0)
        else
          raw_index += 1
          visible_index += 1
        end
      end

      raw_index
    end
  end
end
