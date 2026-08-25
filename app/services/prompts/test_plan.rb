module Prompts
  # Test-plan step prompt for Initial workflows. Spawned as a short
  # agent call with session context from the implementation, so the
  # agent can turn what it just changed into reviewer-facing checks.
  class TestPlan
    def to_s
      <<~PROMPT.strip
        You just finished implementing and summarizing a Syrus run. When
        this turn is resumed, your previous conversation contains the issue,
        the files you read, the diff you produced, and any edge cases you
        noticed. If this turn is not resumed, inspect the current workspace,
        branch diff, and available Syrus context instead.

        Review that implementation context and produce a concise,
        actionable test plan for a human reviewer or operator to follow,
        not instructions for another agent. Call the `submit_test_plan`
        MCP tool. If your tool list shows a prefixed MCP name, call the
        exact prefixed name shown there; do not call bare `submit_test_plan`
        unless that exact bare name is available.

        - `steps`: a JSON array of 1-5 short strings. Each string should be
          one reviewer action: an exact user flow, URL, command, or edge case.
          Keep each step under 240 characters; split or omit detail instead
          of writing long paragraphs.
        - `notes`: optional short context for reviewers, under 500 characters.

        Use normal JSON arguments only. For example:
        `{ "steps": ["Run bin/rspec spec/services/example_spec.rb", "Open /jobs/123 and verify the changed UI."], "notes": "Focus on the new workflow state." }`
        Never use placeholder syntax such as `<parameter name="item">`.
        Never use object keys like `"0"`, `"item"`, or duplicate `"steps"` keys.

        Don't recap the whole conversation in your reply. Don't make
        additional commits. Just call the available `submit_test_plan` tool
        name with valid JSON arguments and exit.
      PROMPT
    end
  end
end
