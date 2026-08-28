module Evals
  # Renders a captured provider transcript_jsonl into a compact, readable
  # log for the verifier prompt. Reuses ClaudeTranscript (app/services) --
  # the same parser the admin transcript viewer uses -- instead of
  # re-parsing the JSONL shape here. A verdict on rubrics like "did the
  # agent run a destructive git command" or "did it run the test suite"
  # needs the *tool calls*, not just the final diff: a violation can be
  # fully reverted by the time the run ends and still show up here.
  module TranscriptRenderer
    MAX_TOOL_RESULT_CHARS = 800

    def self.render(transcript_jsonl)
      return "(no transcript captured)" if transcript_jsonl.blank?

      lines = []
      ClaudeTranscript.new(transcript_jsonl).events.each do |event|
        case event.kind
        when :assistant_text
          text = event.data[:text].to_s.strip
          lines << "[assistant] #{text}" if text.present?
        when :tool_use
          lines << "[tool_use] #{event.data[:name]} #{JSON.generate(event.data[:input])}"
        when :tool_result
          content = truncate(stringify(event.data[:content]))
          marker = event.data[:error] ? "tool_result(error)" : "tool_result"
          lines << "[#{marker}] #{content}"
        end
      end
      lines.join("\n")
    rescue StandardError => e
      "(failed to render transcript: #{e.class}: #{e.message})"
    end

    def self.truncate(text)
      return text if text.length <= MAX_TOOL_RESULT_CHARS

      "#{text[0, MAX_TOOL_RESULT_CHARS]}... (truncated, #{text.length} chars total)"
    end
    private_class_method :truncate

    # tool_result content can be a plain string or an array of content
    # blocks (e.g. `[{"type"=>"text","text"=>"..."}]`) depending on the
    # tool; normalize either shape to plain text for the log.
    def self.stringify(content)
      case content
      when String then content
      when Array
        content.filter_map { |block| block.is_a?(Hash) ? block["text"] : block.to_s }.join("\n")
      else
        content.to_s
      end
    end
    private_class_method :stringify
  end
end
