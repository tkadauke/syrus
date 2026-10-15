module DesignDocs
  class AgentMentionDetector
    MENTION_PATTERN = /(?<![\w])@syrus\b/i

    def self.mentioned?(body, previous_body: nil)
      new(body: body, previous_body: previous_body).mentioned?
    end

    def initialize(body:, previous_body: nil)
      @body = body.to_s
      @previous_body = previous_body
    end

    def mentioned?
      current_mentions = mentioned_outside_quoted_code?(@body)
      return false unless current_mentions
      return true if @previous_body.nil?

      !mentioned_outside_quoted_code?(@previous_body.to_s)
    end

    private

    def mentioned_outside_quoted_code?(text)
      searchable_lines(text).any? { |line| line.match?(MENTION_PATTERN) }
    end

    def searchable_lines(text)
      fence = nil
      text.each_line.filter_map do |line|
        stripped = line.strip
        if (marker = fence_marker(stripped, fence))
          fence = toggle_fence_for_line(stripped, marker, fence)
          next
        end
        next if fence
        next if stripped.start_with?(">")

        line.gsub(/`[^`\n]*`/, "")
      end
    end

    def fence_marker(line, fence)
      pattern = fence ? /\A#{Regexp.escape(fence[0])}{#{fence.length},}/ : /\A(`{3,}|~{3,})/
      line[pattern]
    end

    def toggle_fence_for_line(line, marker, fence)
      character = (fence || marker)[0]
      minimum_length = fence ? fence.length : marker.length
      marker_count = line.scan(/#{Regexp.escape(character)}{#{minimum_length},}/).length

      marker_count.odd? ? (fence || marker) : nil
    end
  end
end
