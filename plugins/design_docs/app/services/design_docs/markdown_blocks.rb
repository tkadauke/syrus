module DesignDocs
  module MarkdownBlocks
    BLOCK_MARKER_PATTERN = /\A\s{0,3}(\#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?|`{3,}|~{3,})/

    Line = Data.define(:text, :start_offset, :end_offset, :marker, :in_fenced_code) do
      def block_marker? = marker.present?
      def heading? = marker.to_s.start_with?("#")
    end

    class << self
      def lines(markdown)
        text = markdown.to_s
        offset = 0
        fence_state = nil

        text.each_line.map do |line|
          marker = marker_for(line, fence_state)
          line_start = offset
          offset += line.length
          line_end = offset
          opening_fence = fence_state.nil? && fence_marker?(marker)
          closing_fence = fence_state && closing_fence_marker?(marker, fence_state)
          fenced_code_line = fence_state.present? && !closing_fence
          fence_state = fence_info(marker) if opening_fence
          fence_state = nil if closing_fence

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

      def marker_for(line, fence_state)
        match = BLOCK_MARKER_PATTERN.match(line)
        return nil unless match

        marker = match[1]
        return fence_marker?(marker) ? marker : nil if fence_state == true
        return nil if fence_state && !closing_fence_marker?(marker, fence_state)

        marker
      end

      def fence_marker?(marker)
        fence_info(marker).present?
      end

      def closing_fence_marker?(marker, fence_state)
        info = fence_info(marker)
        info && info[:character] == fence_state[:character] && info[:length] >= fence_state[:length]
      end

      def fence_info(marker)
        text = marker.to_s
        return { character: "`", length: text.length } if text.match?(/\A`{3,}\z/)
        return { character: "~", length: text.length } if text.match?(/\A~{3,}\z/)

        nil
      end
    end
  end
end
