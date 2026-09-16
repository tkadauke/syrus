module Prompts
  # Prompt for the investigate step of `investigation` Workflows. Renders
  # the operator's free-form investigation prompt (the Job's synthetic
  # issue body) with the same safety/context blocks Prompts::Implement and
  # Prompts::Skill use, plus a phased-execution note explaining that a
  # separate submit_report step -- not this one -- is where findings get
  # written up.
  class Investigation
    def initialize(issue:, epic: nil, job: nil, user: nil, repository_ids: [])
      @issue = issue
      @epic = epic
      @job = job
      @user = user
      @repository_ids = repository_ids
    end

    def to_s
      [ instructions, epic_context, memory_context, GitSafety::TEXT, ShellCommandExecutionContract::TEXT, phased_execution_note ].compact_blank.join("\n\n")
    end

    private

    def instructions
      <<~TXT.strip
        You are running an investigation-only Job: no pull request is
        expected, and there is no requirement to change any code. Explore
        the repository -- read files, search, run tests -- and answer the
        request below with a clear, evidence-based narrative. A thorough
        answer with no code changes is a fully successful outcome; do not
        manufacture changes just to produce a diff.

        If the request calls for looking at the running app, start a
        preview with `start_preview` and drive it with the browser tools;
        call `stop_preview` when you're done with it. As you gather
        evidence -- a query log, a config dump, a screenshot -- capture it
        with `submit_artifact` (structured data) or `submit_visual_artifact`
        (screenshots) so it's attached to this run. Note the exact
        artifact `type` each call reports back; the follow-up report step
        can point at that evidence by `type`, in the order that best
        supports your narrative.

        Investigation request:

        #{@issue.body.to_s.strip}
      TXT
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s
    end

    def memory_context
      Prompts::MemoryContext.new(user: @user, repository_ids: @repository_ids).to_s.presence
    end

    def phased_execution_note
      <<~TXT.strip
        ---

        Phased execution note: you're running the **investigate** step.
        Do the investigation now. DO NOT call `submit_report` here. A
        separate, short follow-up step will ask you to turn your findings
        into a report -- your full context will be available to it via
        session resume, so you don't need to write the report ahead of
        time.
      TXT
    end
  end
end
