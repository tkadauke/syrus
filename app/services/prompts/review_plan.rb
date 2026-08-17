module Prompts
  # review_plan step prompt for Initial/Retry workflows. Spawned as a short
  # resumed agent call after the PR has been opened, so the agent can turn
  # its own implementation into a self-review pointing reviewers at the
  # parts of the diff most worth scrutinizing.
  class ReviewPlan
    def to_s
      <<~PROMPT.strip
        You just finished implementing this change, and the PR is now open.
        When this turn is resumed, your previous conversation contains the
        issue, the files you read, and the diff you produced. If this turn
        is not resumed, inspect the current workspace and branch diff
        instead.

        Do a self-review pass over your own diff, as if you were a careful
        senior engineer reviewing someone else's PR. Call the
        `submit_review_plan` MCP tool. If your tool list shows a prefixed
        MCP name, call the exact prefixed name shown there; do not call
        bare `submit_review_plan` unless that exact bare name is available.

        - `items`: an array of 2-6 specific, high-signal points, each with
          `file`, an optional `line`, and a `note` explaining *why* a human
          reviewer should look closely there (a tricky concurrency
          assumption, a retry-loop edge case, a test gap, a migration risk,
          etc.) — not a restatement of what the diff does.
        - `summary`: optional short overall note.

        Skip items for routine or obvious changes. If nothing about this
        diff stands out as worth extra scrutiny, submit an empty `items`
        array rather than padding it with filler.

        Don't recap the whole conversation in your reply. Don't make
        additional commits. Just call the available `submit_review_plan`
        tool name and exit.
      PROMPT
    end
  end
end
