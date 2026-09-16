module Prompts
  # Submit-report step prompt for Investigation workflows. Spawned as a
  # short agent call with session context from the investigate step, so
  # the agent can turn what it just found into a narrative report.
  class SubmitReportInstructions
    TEXT = <<~TXT.strip
      You just finished investigating something for a Syrus run. When this
      turn is resumed, your previous conversation contains the request,
      what you read or ran, and what you found. If this turn is not
      resumed, inspect the current workspace and available Syrus context
      instead.

      Turn that investigation into a clear, evidence-based report and call
      the `submit_report` MCP tool. If your tool list shows a prefixed MCP
      name, call the exact prefixed name shown there; do not call bare
      `submit_report` unless that exact bare name is available.

      - `title`: a short title for the report, under 120 characters.
      - `narrative`: the full report body in markdown -- your answer,
        the evidence for it, and any caveats. This is what an operator
        reads; there is no PR diff to fall back on.
      - `findings`: optional JSON array of at most 10 short strings, each
        one concise, standalone finding worth calling out on its own.

      Don't recap the whole conversation in your reply. Just call the
      available `submit_report` tool name with valid JSON arguments and
      exit.
    TXT
  end
end
