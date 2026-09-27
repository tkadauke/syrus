module Prompts
  # Asks the agent to write a PR title + body given the issue + the
  # diff it just produced. Single-shot — no tool exploration. Output
  # is JSON so the parser is dumb and unambiguous.
  # GitHub-sourced content trust boundary
  class PullRequestSummary
    include GithubContentTrust

    MAX_DIFF_BYTES = 30_000  # claude context budget — agent rarely needs more

    def initialize(issue:, diff:)
      @issue = issue
      @diff = diff
    end

    def to_s
      <<~PROMPT.strip
        #{github_content_trust_boundary}

        You just produced a code change to address a GitHub issue. Write a clear pull-request title and description for it.

        # Original issue
        Title: #{@issue.title}

        Body:
        #{@issue.body.to_s.strip.presence || '(empty)'}

        # The diff you produced
        ```diff
        #{trimmed_diff}
        ```

        # Output format

        RESPOND WITH A SINGLE JSON OBJECT AND NOTHING ELSE. NO PREAMBLE. NO EXPLANATION. NO MARKDOWN CODE FENCES AROUND THE JSON. NO TEXT BEFORE OR AFTER. JUST THE JSON.

        {
          "title": "...",
          "body": "..."
        }

        - `title`: 50–72 characters, imperative mood ("Add greeting helper", not "Added greeting helper" or "This PR adds…"), no leading prefix or repo slug.
        - `body`: markdown, 1–3 short paragraphs. Lead with the why; mention what changed. Skip ceremony like "This PR…" or restating the title. No headings. Embed line breaks in the JSON string as `\\n`.
      PROMPT
    end

    private

    def trimmed_diff
      return @diff if @diff.bytesize <= MAX_DIFF_BYTES
      "#{@diff.safe_byteslice(0, MAX_DIFF_BYTES)}\n…[truncated, #{@diff.bytesize - MAX_DIFF_BYTES} more bytes]"
    end
  end
end
