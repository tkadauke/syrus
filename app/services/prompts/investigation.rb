module Prompts
  # Prompt for the investigate step of `investigation` Workflows. Renders
  # the resolved `investigate-and-report` Skills::Definition (repo-local
  # override, else Skills::InvestigateAndReport -- see Steps::Investigate)
  # with the operator's free-form investigation request (the Job's
  # synthetic issue body) substituted in, plus the same safety/context
  # blocks Prompts::Implement and Prompts::Skill use, and a
  # phased-execution note explaining that a separate submit_report step --
  # not this one -- is where findings get written up.
  class Investigation
    def initialize(definition:, request:, epic: nil, job: nil, user: nil, repository_ids: [])
      @definition = definition
      @request = request
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
      Skills::Renderer.render(@definition, { "request" => @request.to_s.strip })
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
