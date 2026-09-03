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
      in_fence = false
      text.each_line.filter_map do |line|
        stripped = line.strip
        if stripped.start_with?("```", "~~~")
          in_fence = !in_fence
          next
        end
        next if in_fence
        next if stripped.start_with?(">")

        line.gsub(/`[^`\n]*`/, "")
      end
    end
  end
end
