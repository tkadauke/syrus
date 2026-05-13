module Prompts
  class GradeFailureFeedback
    INLINE_LIMIT = 32 * 1024
    HEAD_BYTES = 4 * 1024
    TAIL_BYTES = 8 * 1024

    def initialize(iterations:)
      @iterations = iterations || []
    end

    def to_s
      [ body, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def body
      return empty_body if @iterations.empty?

      <<~PROMPT.strip
        The previous iteration's quality graders flagged issues. Here are
        the results from every iteration so far:

        #{render_iterations}

        Pick the smallest correct change that resolves the failing required
        graders without regressing the passing ones. Inspect the full log
        file directly if the head+tail excerpt isn't sufficient.
      PROMPT
    end

    def empty_body
      <<~PROMPT.strip
        No prior quality grader iterations were recorded yet.

        Continue with the requested implementation, and preserve any passing
        behavior already present in the repository.
      PROMPT
    end

    def render_iterations
      @iterations.each_with_index.map do |entries, index|
        <<~BLOCK.strip
          == Iteration #{index + 1} ==
          #{render_entries(Array(entries), index + 1)}
        BLOCK
      end.join("\n\n")
    end

    def render_entries(entries, iteration)
      return "  - no grader results recorded" if entries.empty?

      entries.map { |entry| render_entry(entry, iteration) }.join("\n")
    end

    def render_entry(entry, iteration)
      case status(entry)
      when "passed", "success", "succeeded"
        "  \u2713 #{name(entry)}"
      when "failed"
        render_failed_entry(entry, iteration)
      when "skipped"
        "  - #{name(entry)} (skipped#{skip_reason(entry)})"
      else
        "  - #{name(entry)} (#{status(entry) || "unknown"})"
      end
    end

    def render_failed_entry(entry, iteration)
      output = output_for(entry)
      parts = [ exit_code(entry), duration(entry) ].compact
      parts << "output #{format_bytes(output.bytesize)} - truncated" if output.bytesize > INLINE_LIMIT

      summary = "  \u2717 #{name(entry)}"
      summary += " (#{parts.join(", ")})" if parts.any?

      [ summary, render_output(entry, iteration, output) ].compact.join("\n")
    end

    def render_output(entry, iteration, output)
      if output.empty?
        path = log_path(entry, iteration)
        return nil unless path

        return indent("Full log: #{path}", by: 4)
      end

      if output.bytesize <= INLINE_LIMIT
        indent(output, by: 4)
      else
        omitted = output.bytesize - HEAD_BYTES - TAIL_BYTES
        <<~OUTPUT.chomp
            Head:
        #{indent(output.byteslice(0, HEAD_BYTES), by: 6)}
            ... [truncated #{omitted} bytes] ...
            Tail:
        #{indent(output.byteslice(-TAIL_BYTES, TAIL_BYTES), by: 6)}
            Full log: #{log_path(entry, iteration)}
        OUTPUT
      end
    end

    def output_for(entry)
      output = value(entry, :output) || value(entry, :log)
      output ||= [ value(entry, :stdout), value(entry, :stderr) ].compact.join
      output.to_s
    end

    def name(entry)
      value(entry, :name).presence || "unnamed-grader"
    end

    def status(entry)
      value(entry, :status)&.to_s
    end

    def duration(entry)
      duration = value(entry, :duration_s)
      return nil if duration.nil?

      "#{duration}s"
    end

    def exit_code(entry)
      code = value(entry, :exit_code)
      return nil if code.nil?

      "exit #{code}"
    end

    def skip_reason(entry)
      reason = value(entry, :skip_reason) || value(entry, :reason)
      reason.present? ? " - #{reason}" : ""
    end

    def log_path(entry, iteration)
      value(entry, :log_path).presence || ".syrus/grade-output/iteration-#{iteration}/#{name(entry)}.log"
    end

    def format_bytes(bytes)
      return "#{bytes} B" if bytes < 1024

      "#{(bytes / 1024.0).ceil} KB"
    end

    def value(entry, key)
      entry[key.to_s] || entry[key.to_sym]
    end

    def indent(text, by:)
      pad = " " * by
      text.to_s.lines.map { |line| pad + line }.join.chomp
    end
  end
end
