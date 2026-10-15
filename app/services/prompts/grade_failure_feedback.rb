module Prompts
  class GradeFailureFeedback
    INLINE_LIMIT = 32 * 1024
    HEAD_BYTES = 4 * 1024
    TAIL_BYTES = 8 * 1024

    def initialize(iterations:, intro: nil, include_guidance: true, include_git_safety: true, log_manifest: {})
      @iterations = iterations || []
      @intro = intro
      @include_guidance = include_guidance
      @include_git_safety = include_git_safety
      @log_manifest = (log_manifest || {}).to_h
    end

    def to_s
      # NB: no SubmitSummaryInstructions here. This prompt is only
      # appended during a grade-loop iteration (Implement → Grade,
      # Respond → Grade). Telling the agent to submit_summary right
      # before the grader runs is wasted effort: if the grader fails,
      # the next iteration's submit_summary will replace it, and the
      # artifact churn bloats the workflow's artifacts column. The
      # dedicated summarize / summarize_amend step (after the loop
      # terminates) is the one that calls submit_summary.
      parts = [body]
      parts << GitSafety::TEXT if @include_git_safety
      parts.join("\n\n")
    end

    private

    def body
      return empty_body if @iterations.empty?

      guidance = if @include_guidance
        <<~GUIDANCE

          Pick the smallest correct change that resolves the failing required
          graders without regressing the passing ones.
          #{log_access_guidance}

          #{failure_guidance}
        GUIDANCE
      end

      <<~PROMPT.strip
        #{@intro || "The previous iteration's quality graders flagged issues. Here are\nthe results from every iteration so far:"}

        #{render_iterations}
        #{guidance}
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

      [ summary, render_command(entry), render_output(entry, iteration, output) ].compact.join("\n")
    end

    def render_command(entry)
      command = value(entry, :command).to_s.presence
      return nil unless command

      indent("Reproduce with: #{command}", by: 4)
    end

    def render_output(entry, iteration, output)
      archived = archived_entry(entry, iteration)
      return render_archived_output(archived) if archived

      if output.empty?
        path = log_path(entry, iteration)
        return nil unless path

        return indent("Full log: #{path} (may be in the grader checkout; re-run the command above if unavailable here)", by: 4)
      end

      if output.bytesize <= INLINE_LIMIT
        indent(output, by: 4)
      else
        omitted = output.bytesize - HEAD_BYTES - TAIL_BYTES
        <<~OUTPUT.chomp
            Head:
        #{indent(output.safe_byteslice(0, HEAD_BYTES), by: 6)}
            ... [truncated #{omitted} bytes] ...
            Tail:
        #{indent(output.safe_byteslice(-TAIL_BYTES, TAIL_BYTES), by: 6)}
            Full log: #{log_path(entry, iteration)} (may be in the grader checkout; re-run the command above if unavailable here)
        OUTPUT
      end
    end

    # The archived log for this grader in this iteration, if GraderCollect
    # captured one. Looked up by grader name within the iteration, because a
    # single iteration can fail several graders at once.
    def archived_entry(entry, iteration)
      entries = @log_manifest[iteration.to_s] || @log_manifest[iteration]
      Array(entries).map(&:to_h).find do |candidate|
        (candidate["name"] || candidate[:name]).to_s == name(entry)
      end
    end

    # A preview and a path, never the log itself. The whole log is on disk in
    # this workspace, so there is no reason to spend prompt budget on it and
    # no reason for the agent to guess at what was cut.
    def render_archived_output(archived)
      reason = archived["unavailable_reason"] || archived[:unavailable_reason]
      if reason.present?
        # A grader can leave no log behind and still have ingested results --
        # test output written just before the process died, for instance. The
        # records are worth showing even though the log is gone.
        salvaged = Array(archived["failure_summary"] || archived[:failure_summary])
        lines = [
          indent(
            "No log was captured for this grader: #{reason}.#{
              salvaged.any? ? "" : " There is nothing to read and nothing to fix from it -- " \
              "treat this grader as inconclusive for this iteration rather than as a code defect."
            }",
            by: 4
          )
        ]
        if salvaged.any?
          lines << indent("Its recorded results survived, though:", by: 4)
          lines << indent(salvaged.join("\n"), by: 6)
        end
        return lines.join("\n")
      end

      path = archived["relative_path"] || archived[:relative_path]
      bytes = (archived["bytes"] || archived[:bytes]).to_i
      preview = (archived["preview"] || archived[:preview]).to_s
      summary = Array(archived["failure_summary"] || archived[:failure_summary])

      sections = []

      # An exact account from whichever plugin ingested this grader's results,
      # when one is available. It beats the preview outright -- the preview is
      # scraped out of log text and can miss failures the records already
      # know about -- so it goes first and the preview is dropped.
      if summary.any?
        sections << indent("What failed (complete list, from this grader's own results):", by: 4)
        sections << indent(summary.join("\n"), by: 6)
      end

      if path.present?
        sections << indent("Full log, complete and untruncated (#{format_bytes(bytes)}): #{path}", by: 4)
        sections << indent(
          if summary.any?
            "Open it for the detail behind any of the failures above."
          else
            "Read that file before changing anything. The lines below are only a short preview of it."
          end,
          by: 4
        )
        sections << indent("Preview:\n#{preview}", by: 6) if summary.empty? && preview.present?
      end

      sections.join("\n").presence
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

    # When logs were archived, the agent has the whole thing on disk and must
    # be told so explicitly -- otherwise it treats the preview as all there is
    # and starts guessing, which is exactly the failure mode this replaced.
    def log_access_guidance
      if @log_manifest.present?
        <<~GUIDANCE.strip
          Each failing grader above lists a log path in this workspace. Those
          files hold that grader's complete output with nothing removed --
          open them with your normal file tools and work from what they
          actually say. Do not infer the failure from the preview alone, and
          do not re-run a whole grader just to see output you already have.
          Re-run a command only to reproduce a specific failure in isolation
          or to check a fix.
        GUIDANCE
      else
        <<~GUIDANCE.strip
          Inspect the full log file directly if the excerpt isn't sufficient.
          If the full log path is not present in this workspace, re-run the
          exact command shown for the failing grader and use that output as
          the source of truth.
        GUIDANCE
      end
    end

    def failure_guidance
      if GraderFailureSignal.timeout_only_latest_failure?(@iterations)
        <<~PROMPT.strip
          The latest required grader failure looks timeout-only. Treat that as
          inconclusive: do not call `report_main_concern` solely because a test
          or command timed out. Inspect the timeout, reduce the slow path, or
          ask the operator to raise the relevant timeout.
        PROMPT
      else
        <<~PROMPT.strip
          If CI or graders are failing in files you did not touch, call
          `report_main_concern` with your reasoning before retrying. Do not
          burn retries on a systemic failure.

          If you suspect a specific failing test is flaky rather than a real
          regression, run that exact example in isolation, against the
          current commit, BEFORE making any fix. If it does not reproduce,
          call `record_isolated_repro` for that exact reported example. Syrus
          derives and reruns the focused command itself; this is structured,
          auditable evidence, not a broad rerun of the whole grader and not
          just your opinion that it's flaky.
        PROMPT
      end
    end

    def value(entry, key)
      entry.key?(key.to_s) ? entry[key.to_s] : entry[key.to_sym]
    end

    def indent(text, by:)
      pad = " " * by
      text.to_s.lines.map { |line| pad + line }.join.chomp
    end
  end
end
