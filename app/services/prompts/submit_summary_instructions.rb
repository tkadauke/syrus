module Prompts
  # Trailing block appended to every primary-agent prompt (Initial,
  # PrFeedback, …) telling the agent to call the `submit_summary` MCP
  # tool. Single source for the wording so we tune it once and both
  # paths benefit.
  module SubmitSummaryInstructions
    TEXT = <<~TXT.strip
      ---

      When you finish, CALL THE `submit_summary` MCP TOOL with three
      fields:

      - `pr_title`: 50–72 chars, imperative mood ("Add greeting helper",
        not "Adds greeting helper" or "This PR adds…"). No leading prefix
        or repo slug. On the initial run this becomes the GitHub PR title;
        on follow-up runs (pr_comment, retry, etc.) the PR already exists
        and this becomes the git commit message — describe what changed *in
        this revision*, not the whole PR (e.g. "Address review feedback:
        validate empty input on UserForm").
      - `pr_body`: markdown, 1–3 short paragraphs. Lead with the why; then
        mention what changed. No headings, no "This PR…" preamble.
      - `summary`: 1–2 sentences describing what you did. Operator-facing,
        shown on the Syrus job page.

      DO NOT include the title or body in your final assistant text — call
      the tool. Syrus reads them from the tool, not from the transcript.
    TXT
  end
end
