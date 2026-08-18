require "json"

module CiRepair
  # Builds the plain-language-ready digest content the `explain-failing-ci`
  # skill hands its agent turn: which checks failed and why. Pure function
  # of a CiRepair::CheckRefresh::Result — the same fetch
  # `refresh_pr_checks`/`mergeability_preflight` already call — so it's
  # testable against a hand-built fixture with no GitHub API involved.
  #
  # Reuses CiRepair::CheckEnricher (the same log-parsing `ci_failure` Runs
  # use via Prompts::CiFailure) for structured per-check error context,
  # rather than re-deriving log parsing for a second time.
  class FailureDigest
    MAX_CHECKS = 10
    MAX_SUMMARY_BYTES = 2_000
    MAX_ERROR_BLOCK_BYTES = 6_000

    def self.call(result)
      new(result).call
    end

    def initialize(result)
      @result = result
    end

    def call
      case @result.state
      when "pending" then pending_text
      when "passing" then passing_text
      when "failing" then failing_text
      else unknown_text
      end
    end

    private

    def pr_ref
      number = @result.job.pr_number || @result.job.external_pr_number
      sha = @result.head_sha.to_s.first(7)
      "PR ##{number} at #{sha}".strip
    end

    def pending_text
      "CI is still running for #{pr_ref} — no check has completed as failed " \
        "yet. There is nothing to diagnose: report that checks are still in " \
        "progress and that no verdict is available yet."
    end

    def passing_text
      "CI is currently green for #{pr_ref} — every check has completed and " \
        "passed. There is no failure to explain; report that the checks are " \
        "currently passing."
    end

    def unknown_text
      "No check runs were found for #{pr_ref}. Report that there is nothing " \
        "to explain."
    end

    def failing_text
      checks = Array(@result.failed_checks)
      shown = checks.first(MAX_CHECKS)
      truncated_note = checks.size > shown.size ? ", showing #{shown.size}" : ""

      <<~TXT.strip
        CI is failing for #{pr_ref} (#{checks.size} failing check#{"s" if checks.size != 1}#{truncated_note}):

        #{shown.map { |check| render_check(check) }.join("\n\n")}
      TXT
    end

    def render_check(check)
      enriched = CiRepair::CheckEnricher.call(check)
      summary = value(enriched, :summary).to_s.strip
      summary = "(no summary provided)" if summary.empty?
      summary = truncate(summary, MAX_SUMMARY_BYTES)

      <<~BLOCK.strip
        ## #{value(enriched, :name)} — #{value(enriched, :conclusion)}
        Full log: #{value(enriched, :html_url)}

        GitHub summary:
        #{summary}

        Structured error context:
        ```json
        #{JSON.pretty_generate(structured_context(enriched))}
        ```
      BLOCK
    end

    # CiRepair::CheckEnricher always attaches a non-blank :error_context
    # (CiLogParser#parse never returns nil, even for an empty/unmatched
    # log — it falls through to a "fallback"-parsed hash), so there is no
    # blank-context case to special-case here, unlike a check that never
    # went through the enricher.
    def structured_context(check)
      context = value(check, :error_context).to_h.deep_stringify_keys

      error_block = context["error_block"].to_s
      if error_block.bytesize > MAX_ERROR_BLOCK_BYTES
        context["error_block"] = "#{error_block.safe_byteslice(0, MAX_ERROR_BLOCK_BYTES)}\n...[truncated]"
      end
      context
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end

    def truncate(text, max_bytes)
      return text if text.bytesize <= max_bytes

      "#{text.safe_byteslice(0, max_bytes)}\n…[truncated]"
    end
  end
end
