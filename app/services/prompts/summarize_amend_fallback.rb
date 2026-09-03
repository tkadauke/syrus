module Prompts
  # Bounded follow-up summary prompt for the rare case where the provider
  # cannot resume the upstream repair session. It preserves SummarizeAmend's
  # "commit message for this revision" framing without relying on rollout state.
  class SummarizeAmendFallback
    MAX_BODY_BYTES = 16 * 1024
    MAX_DIFF_BYTES = Prompts::PullRequestSummary::MAX_DIFF_BYTES

    def initialize(issue:, trigger_kind:, upstream_step_kind:, diff:)
      @issue = issue
      @trigger_kind = trigger_kind.to_s
      @upstream_step_kind = upstream_step_kind.to_s
      @diff = diff.to_s
    end

    def to_s
      <<~PROMPT.strip
        You just finished a follow-up Syrus workflow, but the original agent
        session is not available to resume. Use this bounded durable context
        instead.

        The PR for this Job already exists. Produce the follow-up commit
        message by calling the `submit_summary` MCP tool. If your tool list
        shows a prefixed MCP name, call the exact prefixed name shown there;
        do not call bare `submit_summary` unless that exact bare name is
        available.

        - `pr_title`: a one-line commit message describing what changed in
          this revision, not the whole PR. Imperative mood. Examples:
          "Address review feedback: validate empty input on UserForm" or
          "Fix CI: update timeout expectation".
        - `pr_body`: 1-2 short paragraphs of context about the feedback or
          failure and the fix. Markdown, no headings, no "This commit..."
          preamble.
        - `summary`: 1 sentence operator-facing.

        Do not edit files, run commands, or make commits. Just call the
        available `submit_summary` tool name and exit.

        # Workflow context
        Trigger kind: #{trigger_kind_text}
        Upstream step: #{upstream_step_text}

        # Original job
        Title: #{@issue.title}

        Body:
        #{trimmed_body}

        # Follow-up diff
        ```diff
        #{trimmed_diff}
        ```
      PROMPT
    end

    private

    def trigger_kind_text
      @trigger_kind.presence || "(unknown)"
    end

    def upstream_step_text
      @upstream_step_kind.presence || "(unknown)"
    end

    def trimmed_body
      body = @issue.body.to_s.strip
      return "(empty)" if body.blank?
      return body if body.bytesize <= MAX_BODY_BYTES

      "#{body.safe_byteslice(0, MAX_BODY_BYTES)}\n...[truncated, #{body.bytesize - MAX_BODY_BYTES} more bytes]"
    end

    def trimmed_diff
      return "(empty)" if @diff.blank?
      return @diff if @diff.bytesize <= MAX_DIFF_BYTES

      "#{@diff.safe_byteslice(0, MAX_DIFF_BYTES)}\n...[truncated, #{@diff.bytesize - MAX_DIFF_BYTES} more bytes]"
    end
  end
end
