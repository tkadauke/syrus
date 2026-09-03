module Prompts
  # Fallback summarize-amend prompt for the rare case where the upstream
  # provider session is unavailable to resume. It gives the agent durable job
  # context plus the follow-up diff so it can submit commit metadata only.
  class SummarizeAmendFallback
    MAX_BODY_BYTES = 16 * 1024
    MAX_SUMMARY_BYTES = 8 * 1024
    MAX_DIFF_BYTES = Prompts::PullRequestSummary::MAX_DIFF_BYTES

    def initialize(issue:, summary:, diff:)
      @issue = issue
      @summary = summary.to_s
      @diff = diff.to_s
    end

    def to_s
      <<~PROMPT.strip
        You just finished addressing follow-up work for this Syrus job, but the
        original agent session is not available to resume. Use this bounded
        durable context instead.

        The PR for this Job already exists; this is a follow-up commit, not a
        new PR. Produce the commit metadata by calling the `submit_summary` MCP
        tool. If your tool list shows a prefixed MCP name, call the exact prefixed
        name shown there; do not call bare `submit_summary` unless
        that exact bare name is available.

        - `pr_title`: a one-line commit message describing what changed in this
          revision, not the whole PR. Use imperative mood.
        - `pr_body`: 1-2 short paragraphs of context: what feedback or failure
          prompted the change, and what changed in response.
        - `summary`: 1 sentence operator-facing.

        Do not edit files, run commands, or make commits. The previous step
        already committed the work. Just call the available `submit_summary`
        tool name with valid JSON arguments and exit.

        # Original job
        Title: #{@issue.title}

        Body:
        #{trimmed_body}

        # Existing PR context
        #{trimmed_summary}

        # Follow-up diff
        ```diff
        #{trimmed_diff}
        ```
      PROMPT
    end

    private

    def trimmed_body
      body = @issue.body.to_s.strip
      return "(empty)" if body.blank?
      return body if body.bytesize <= MAX_BODY_BYTES

      "#{body.safe_byteslice(0, MAX_BODY_BYTES)}\n...[truncated, #{body.bytesize - MAX_BODY_BYTES} more bytes]"
    end

    def trimmed_summary
      summary = @summary.strip
      return "(empty)" if summary.blank?
      return summary if summary.bytesize <= MAX_SUMMARY_BYTES

      "#{summary.safe_byteslice(0, MAX_SUMMARY_BYTES)}\n...[truncated, #{summary.bytesize - MAX_SUMMARY_BYTES} more bytes]"
    end

    def trimmed_diff
      return "(empty)" if @diff.blank?
      return @diff if @diff.bytesize <= MAX_DIFF_BYTES

      "#{@diff.safe_byteslice(0, MAX_DIFF_BYTES)}\n...[truncated, #{@diff.bytesize - MAX_DIFF_BYTES} more bytes]"
    end
  end
end
