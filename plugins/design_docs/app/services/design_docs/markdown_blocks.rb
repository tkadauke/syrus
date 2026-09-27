module DesignDocs
  module MarkdownBlocks
    BLOCK_MARKER_PATTERN = /\A\s{0,3}(\#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?|```|~~~)/

    Line = Data.define(:text, :start_offset, :end_offset, :marker, :in_fenced_code) do
      def block_marker? = marker.present?
      def heading? = marker.to_s.start_with?("#")
    end

    class << self
      def lines(markdown)
        text = markdown.to_s
        offset = 0
        in_fenced_code = false

        text.each_line.map do |line|
          marker = marker_for(line, in_fenced_code)
          line_start = offset
          offset += line.length
          line_end = offset
          fence = fence_marker?(marker)
          fenced_code_line = in_fenced_code && !fence
          in_fenced_code = !in_fenced_code if fence

          Line.new(
            text: line,
            start_offset: line_start,
            end_offset: line_end,
            marker: marker,
            in_fenced_code: fenced_code_line
          )
        end
      end

      def line_at(markdown, offset)
        normalized_offset = offset.to_i
        lines(markdown).find do |line|
          normalized_offset >= line.start_offset && normalized_offset < line.end_offset
        end
      end

      def marker_at_line(line, in_fenced_code: false)
        marker_for(line.to_s, in_fenced_code)
      end

      private

      def marker_for(line, in_fenced_code)
        match = BLOCK_MARKER_PATTERN.match(line)
        return nil unless match

        marker = match[1]
        return nil if in_fenced_code && !fence_marker?(marker)

        marker
      end

      def fence_marker?(marker)
        marker == "```" || marker == "~~~"
      end
    end
  end
end
