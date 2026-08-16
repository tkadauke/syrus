module Prompts
  # Prompt for the run_skill step of `skill` Workflows. Renders a resolved
  # Skills::Definition's instructions with the Job's supplied args
  # (Skills::Renderer), then wraps them in the standard git-safety
  # contract and a phased-execution note — same shape as Prompts::Implement,
  # since run_skill is followed by its own `summarize` step and must not
  # call `submit_summary` itself.
  class Skill
    def initialize(definition:, args:, epic: nil, job: nil, user: nil, repository_ids: [])
      @definition = definition
      @args = args
      @epic = epic
      @job = job
      @user = user
      @repository_ids = repository_ids
    end

    def to_s
      [ instructions, epic_context, memory_context, GitSafety::TEXT, phased_execution_note ].compact_blank.join("\n\n")
    end

    private

    def instructions
      "Skill: #{@definition.name}\n\n#{Skills::Renderer.render(@definition, @args)}"
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

        Phased execution note: you're running the **run_skill** step for
        the `#{@definition.name}` skill. If the instructions above call
        for changes, make them and commit locally; that's it. If this
        skill is read-only (for example an investigation) and there is
        nothing to change, that is a valid, successful outcome — do not
        manufacture changes just to produce a diff. Either way, DO NOT
        call `submit_summary` here. A separate, short follow-up step will
        ask you to summarize the work; your full context will be
        available to it via session resume, so you don't need to
        summarize ahead of time.
      TXT
    end
  end
end
