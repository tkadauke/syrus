module DesignDocs
  module SuggestionRendering
    INLINE = "inline".freeze
    BLOCK = "block".freeze

    BLOCK_START_PATTERN = /\A\s{0,3}(?:\#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s?|```|~~~|---+\s*\z|\*\*\*+\s*\z)/.freeze

    module_function

    def render_mode(original_markdown:, proposed_markdown:)
      inline_safe?(original_markdown) && inline_safe?(proposed_markdown) ? INLINE : BLOCK
    end

    def block_level?(original_markdown:, proposed_markdown:)
      render_mode(original_markdown: original_markdown, proposed_markdown: proposed_markdown) == BLOCK
    end

    def inline_safe?(markdown)
      value = markdown.to_s
      return false if value.include?("\n")

      !value.match?(BLOCK_START_PATTERN)
    end

    def partial_block_syntax_selection?(markdown:, start_offset:, end_offset:)
      visible = AnchorMarkers.strip(markdown)
      start_offset = start_offset.to_i.clamp(0, visible.length)
      end_offset = end_offset.to_i.clamp(0, visible.length)
      start_offset, end_offset = end_offset, start_offset if end_offset < start_offset
      return false if start_offset == end_offset

      line_bounds(visible).any? do |line_start, line_end|
        selection_start = [ start_offset, line_start ].max
        selection_end = [ end_offset, line_end ].min
        next false if selection_end <= selection_start

        marker_end = block_marker_end(visible[line_start...line_end].to_s)
        next false unless marker_end

        relative_start = selection_start - line_start
        relative_end = selection_end - line_start
        touches_marker = relative_start < marker_end && relative_end > 0
        touches_block_line = touches_marker || relative_start.zero?
        touches_block_line && !(selection_start == line_start && selection_end == line_end)
      end
    end

    def block_marker_end(line)
      block_marker_patterns.each do |pattern|
        match = pattern.match(line)
        return match.end(0) if match
      end
      return line.length if line.match?(/\A\s{0,3}(?:---+|\*\*\*+)\s*\z/)

      nil
    end

    def block_marker_patterns
      [
        /\A\s{0,3}\#{1,6}\s+/,
        /\A\s{0,3}[-*+]\s+/,
        /\A\s{0,3}\d+[.)]\s+/,
        /\A\s{0,3}>\s?/,
        /\A\s{0,3}(?:```|~~~)/
      ]
    end

    def line_bounds(markdown)
      bounds = []
      start = 0
      markdown.to_s.each_line(chomp: false) do |line|
        line_end = start + line.delete_suffix("\n").length
        bounds << [ start, line_end ]
        start += line.length
      end
      bounds << [ start, start ] if markdown.to_s.empty?
      bounds
    end
  end
end
