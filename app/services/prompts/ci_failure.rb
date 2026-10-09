require "json"

module Prompts
  # Prompt for `ci_failure` Runs. Tells the agent which checks went red
  # on the current PR head, includes the GitHub-provided summary text,
  # and asks for a fix on the existing branch. Same scope rule as
  # PrFeedback: no functional drift, just make the failing checks pass.
  # GitHub-sourced content trust boundary
  class CiFailure
    include GithubContentTrust

    MAX_CHECKS = 5
    MAX_SUMMARY_BYTES = 2_000
    MAX_ERROR_BLOCK_BYTES = 6_000
    MAX_REPAIR_DIFF_BYTES = 2_000

    def initialize(issue:, pr_number:, repo_slug:, branch_name:, head_sha:, failed_checks:, instructions: nil, epic: nil, job: nil, injected_context: [], grader_iterations: [], repair_attempts: [])
      @issue        = issue
      @pr_number    = pr_number
      @repo_slug    = repo_slug
      @branch_name  = branch_name
      @head_sha     = head_sha
      @failed_checks = Array(failed_checks).compact
      @instructions = instructions.to_s.strip.presence
      @epic = epic
      @job = job
      @injected_context = Array(injected_context).compact
      @grader_iterations = Array(grader_iterations)
      @repair_attempts = Array(repair_attempts)
    end

    def to_s
      main_prompt = <<~PROMPT.strip
        #{github_content_trust_boundary}

        CI is failing on PR `#{@repo_slug}##{@pr_number}` (branch `#{@branch_name}` at `#{head_sha_label}`). Fix the failing checks.

        # Original issue
        Title: #{@issue.title}

        Body:
        #{@issue.body.to_s.strip.presence || '(empty)'}

        #{epic_context}

        # Failing checks (#{failing_checks_summary})
        #{render_checks}

        #{grader_feedback_section}

        #{repair_attempts_section}

        #{operator_instructions}

        # How to act

        - Read each failing check's structured error context and each
          blocking grader result above. GitHub check context is extracted
          from the failing CI log when available; grader excerpts are the
          workflow gate that decides whether this repair loop continues.
        - Reproduce the failure locally where possible (run the test,
          run the linter, run the build). The repo is checked out at
          the failing commit.
        - Fix the code so the checks pass. Do **not** silence them by
          deleting tests, disabling linters, or weakening assertions.
        - Stay scoped to the failure. Do not refactor unrelated code,
          do not bump dependency versions speculatively, do not
          rewrite history.
        - Commit the fix. Syrus will push to `#{@branch_name}`; CI
          will re-run. If you can't fix the failure (e.g. it's a flake
          or an environment issue outside the diff's scope), say so
          in `submit_summary` instead of pushing a noop.
      PROMPT

      [ main_prompt, injected_context_section, ShellCommandExecutionContract::TEXT ].compact_blank.join("\n\n")
    end

    private

    def head_sha_label
      sha = @head_sha.to_s.strip
      sha.present? ? sha[0..6] : "unknown head"
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s
    end

    def injected_context_section
      return nil if @injected_context.empty?

      @injected_context.join("\n\n")
    end

    def render_checks
      rendered = @failed_checks.first(MAX_CHECKS).map { |c| render_check(c) }.join("\n\n")
      rendered.presence || "No failing GitHub checks were recorded for this repair trigger."
    end

    def operator_instructions
      return nil unless @instructions

      <<~BLOCK.strip
        # Operator instructions
        #{@instructions}
      BLOCK
    end

    def render_check(check)
      summary = value(check, :summary).to_s.strip
      summary = "(no summary provided)" if summary.empty?
      summary = truncate_summary(summary)
      context = structured_context(check)

      <<~BLOCK.strip
        ## #{value(check, :name)} — #{value(check, :conclusion)}
        Full log: #{value(check, :html_url)}

        GitHub summary:
        #{summary}

        #{target_context_block(check)}

        Structured error context:
        ```json
        #{JSON.pretty_generate(context)}
        ```
      BLOCK
    end

    def failing_checks_summary
      parts = [
        "#{@failed_checks.size} GitHub check(s), showing up to #{MAX_CHECKS}"
      ]
      blocking = blocking_grader_names
      parts << "#{blocking.size} loop-blocking required grader(s): #{blocking.join(', ')}" if blocking.any?
      parts.join("; ")
    end

    def grader_feedback_section
      return nil if @grader_iterations.empty?

      Prompts::GradeFailureFeedback.new(
        iterations: @grader_iterations,
        intro: <<~INTRO.strip,
          The repair loop's own graders are the gate for the next round. These
          are the recorded grader results so far; prioritize failed required
          graders even when they differ from the GitHub check list above.
        INTRO
        include_git_safety: false
      ).to_s
    end

    def repair_attempts_section
      return nil if @repair_attempts.empty?

      <<~BLOCK.strip
        # Previous repair attempts
        #{@repair_attempts.map { |attempt| render_repair_attempt(attempt) }.join("\n")}
      BLOCK
    end

    def render_repair_attempt(attempt)
      attempt = attempt.to_h if attempt.respond_to?(:to_h)
      attempt = {} unless attempt.is_a?(Hash)
      iteration = attempt["iteration"] || attempt[:iteration] || "unknown"
      status = attempt["status"] || attempt[:status] || "unknown"
      diff = (attempt["diff"] || attempt[:diff]).to_s

      line = "- Iteration #{iteration}: #{status}"
      if diff.strip.empty?
        "#{line}; produced no repository diff."
      else
        "#{line}; produced this diff excerpt:\n#{indent(truncate_repair_diff(diff), by: 2)}"
      end
    end

    def blocking_grader_names
      @grader_iterations.flat_map do |entries|
        Array(entries).filter_map do |entry|
          entry = entry.to_h if entry.respond_to?(:to_h)
          entry = {} unless entry.is_a?(Hash)
          required = entry.key?("required") ? entry["required"] : entry[:required]
          status = (entry["status"] || entry[:status]).to_s
          next unless required && status == "failed"

          entry["name"] || entry[:name]
        end
      end.compact.uniq
    end

    def truncate_repair_diff(diff)
      return diff if diff.bytesize <= MAX_REPAIR_DIFF_BYTES

      "#{diff.safe_byteslice(0, MAX_REPAIR_DIFF_BYTES)}\n...[truncated]"
    end

    def indent(text, by:)
      pad = " " * by
      text.to_s.lines.map { |line| pad + line }.join.chomp
    end

    def target_context_block(check)
      context = value(check, :target_context)
      context = context.to_h if context.respond_to?(:to_h)
      context = {} unless context.is_a?(Hash)
      context = context.deep_stringify_keys
      return nil if context.blank?

      <<~BLOCK.strip
        Target context:
        ```json
        #{JSON.pretty_generate(context)}
        ```
      BLOCK
    end

    def structured_context(check)
      context = value(check, :error_context)
      context = context.to_h if context.respond_to?(:to_h)
      context = {} unless context.is_a?(Hash)
      context = context.deep_stringify_keys

      if context.blank?
        fallback_summary = value(check, :summary).to_s
        fallback_summary = truncate_summary(fallback_summary)
        context = {
          "failing_step" => value(check, :name),
          "parser" => "github_summary",
          "error_summary" => fallback_summary.presence || "No summary provided.",
          "failing_tests" => [],
          "offenses" => [],
          "error_block" => fallback_summary,
          "full_log_url" => value(check, :html_url)
        }
      end

      error_block = context["error_block"].to_s
      if error_block.bytesize > MAX_ERROR_BLOCK_BYTES
        context["error_block"] = "#{error_block.safe_byteslice(0, MAX_ERROR_BLOCK_BYTES)}\n...[truncated]"
      end
      context
    end

    def value(hash, key)
      hash = hash.to_h if hash.respond_to?(:to_h)
      hash = {} unless hash.is_a?(Hash)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def truncate_summary(summary)
      return summary if summary.bytesize <= MAX_SUMMARY_BYTES

      "#{summary.safe_byteslice(0, MAX_SUMMARY_BYTES)}\n…[truncated]"
    end
  end
end
