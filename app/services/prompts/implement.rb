module Prompts
  # Implement-step prompt for the Initial workflow. Same shape as
  # the legacy Prompts::Initial (issue title + body + the standard
  # safety/submit-summary blocks), with one key change: the agent
  # is told NOT to call submit_summary in this step. The
  # downstream `summarize` step has a fresh, short claude call
  # (--resumed against this step's session) whose only job is to
  # produce submit_summary. Keeps the implement run focused on
  # implementation; keeps the summary tied to the post-work
  # context the agent has at the end.
  class Implement
    def initialize(issue:, replay_context: nil)
      @issue = issue
      @replay_context = replay_context
    end

    def to_s
      sections = [ "#{@issue.title}\n\n#{@issue.body}".strip ]
      sections << "Additional context from the operator:\n\n#{@replay_context}" if @replay_context.present?
      sections << GitSafety::TEXT
      sections << STEP_NOTE
      sections.join("\n\n")
    end

    STEP_NOTE = <<~TXT.strip
      ---

      Phased execution note: you're running the **implement** step.
      Make the code changes; commit them locally; that's it. DO NOT
      call `submit_summary` here. A separate, short follow-up step
      will ask you to summarize the work for the PR — your full
      context will be available to it via session resume, so you
      don't need to summarize ahead of time. If you finish early,
      just stop your tool calls and let the run end; we'll prompt
      you for the summary on the next step.
    TXT
  end
end
