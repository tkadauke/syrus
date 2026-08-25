module Prompts
  # Fallback test-plan prompt for the rare case where the implementation
  # session is unavailable to resume. It gives the agent bounded durable job
  # context and the produced diff, then asks it to call submit_test_plan.
  class TestPlanFallback
    MAX_BODY_BYTES = 16 * 1024
    MAX_DIFF_BYTES = Prompts::PullRequestSummary::MAX_DIFF_BYTES

    def initialize(issue:, summary:, diff:)
      @issue = issue
      @summary = summary.to_s
      @diff = diff.to_s
    end

    def to_s
      <<~PROMPT.strip
        You just finished the implementation for this Syrus job, but the
        original agent session is not available to resume. Use this bounded
        durable context instead.

        Produce a concise reviewer-facing test plan by calling the
        `submit_test_plan` MCP tool. If your tool list shows a prefixed
        MCP name, call the exact prefixed name shown there; do not call
        bare `submit_test_plan` unless that exact bare name is available.

        - `steps`: a JSON array of 1-5 short strings. Each string should be
          one reviewer action: an exact user flow, URL, command, or edge case.
          Keep each step under 240 characters; split or omit detail instead
          of writing long paragraphs.
        - `notes`: optional short context for reviewers, under 500 characters.

        Use normal JSON arguments only. For example:
        `{ "steps": ["Run bin/rspec spec/services/example_spec.rb", "Open /jobs/123 and verify the changed UI."], "notes": "Focus on the changed behavior." }`
        Never use placeholder syntax such as `<parameter name="item">`.
        Never use object keys like `"0"`, `"item"`, or duplicate `"steps"` keys.

        Do not edit files, run commands, or make commits. Just call the
        available `submit_test_plan` tool name with valid JSON arguments
        and exit.

        # Original job
        Title: #{@issue.title}

        Body:
        #{trimmed_body}

        # PR summary
        #{trimmed_summary}

        # Implementation diff
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
      summary.presence || "(empty)"
    end

    def trimmed_diff
      return "(empty)" if @diff.blank?
      return @diff if @diff.bytesize <= MAX_DIFF_BYTES

      "#{@diff.safe_byteslice(0, MAX_DIFF_BYTES)}\n...[truncated, #{@diff.bytesize - MAX_DIFF_BYTES} more bytes]"
    end
  end
end
