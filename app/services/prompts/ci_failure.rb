require "json"

module Prompts
  # Prompt for `ci_failure` Runs. Tells the agent which checks went red
  # on the current PR head, includes the GitHub-provided summary text,
  # and asks for a fix on the existing branch. Same scope rule as
  # PrFeedback: no functional drift, just make the failing checks pass.
  class CiFailure
    MAX_CHECKS = 5
    MAX_SUMMARY_BYTES = 2_000
    MAX_ERROR_BLOCK_BYTES = 6_000

    def initialize(issue:, pr_number:, repo_slug:, branch_name:, head_sha:, failed_checks:, epic: nil, job: nil)
      @issue        = issue
      @pr_number    = pr_number
      @repo_slug    = repo_slug
      @branch_name  = branch_name
      @head_sha     = head_sha
      @failed_checks = failed_checks
      @epic = epic
      @job = job
    end

    def to_s
      <<~PROMPT.strip
        CI is failing on PR `#{@repo_slug}##{@pr_number}` (branch `#{@branch_name}` at `#{@head_sha[0..6]}`). Fix the failing checks.

        # Original issue
        Title: #{@issue.title}

        Body:
        #{@issue.body.to_s.strip.presence || '(empty)'}

        #{epic_context}

        # Failing checks (#{@failed_checks.size} total, showing up to #{MAX_CHECKS})
        #{render_checks}

        # How to act

        - Read each failing check's structured error context above. It
          is extracted from the failing CI log when available, with the
          full log URL included for deeper investigation.
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
    end

    private

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s
    end

    def render_checks
      @failed_checks.first(MAX_CHECKS).map { |c| render_check(c) }.join("\n\n")
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

        Structured error context:
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
      hash[key] || hash[key.to_s]
    end

    def truncate_summary(summary)
      return summary if summary.bytesize <= MAX_SUMMARY_BYTES

      "#{summary.safe_byteslice(0, MAX_SUMMARY_BYTES)}\n…[truncated]"
    end
  end
end
