module Prompts
  # Test-plan step prompt for Initial workflows. Spawned as a short
  # agent call with session context from the implementation, so the
  # agent can turn what it just changed into reviewer-facing checks.
  class TestPlan
    def to_s
      <<~PROMPT.strip
        You just finished implementing and summarizing a Syrus run. Your
        previous conversation contains the issue, the files you read,
        the diff you produced, and any edge cases you noticed.

        Review that implementation context and produce a concise,
        actionable test plan by calling the `submit_test_plan` MCP tool:

        - `steps`: an array of exact user flows to exercise, URLs or
          commands where relevant, and edge cases you know about from
          writing the code.
        - `notes`: optional short context for reviewers.

        Don't recap the whole conversation in your reply. Don't re-read
        files unless the resumed context is insufficient. Don't make
        additional commits. Just call `submit_test_plan` and exit.
      PROMPT
    end
  end
end
