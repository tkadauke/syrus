module Prompts
  # Summarize-amend prompt for follow-up workflows. Same shape as
  # Prompts::Summarize, but the framing is "you addressed feedback;
  # produce the commit message for THIS revision (not a fresh PR
  # title)". The PR
  # already exists; pr_title/pr_body in the artifact get used as
  # the commit message for the amendment, not a new PR's copy.
  class SummarizeAmend
    def to_s
      <<~PROMPT.strip
        You just finished addressing the prior step's work on a
        Syrus run (PR comment or similar). The PR
        for this Job already exists; this is a *follow-up
        commit*, not a new PR.

        Call the `submit_summary` MCP tool with:

        - `pr_title`: a one-line commit message describing
          what changed *in this revision*, not the whole PR.
          Imperative mood. e.g. "Address review feedback:
          validate empty input on UserForm" or "Fix lint:
          space-inside-array-brackets".
        - `pr_body`: 1–2 short paragraphs of context — what
          feedback / failure prompted the change, what you did
          about it. Markdown, no headings, no "This commit…"
          preamble.
        - `summary`: 1 sentence operator-facing.

        Don't re-read files. Don't make new commits. The
        previous step already committed your work. Just call
        `submit_summary` and exit.
      PROMPT
    end
  end
end
