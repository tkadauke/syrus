module Steps
  # Agentic step of `skill` Workflows (Workflow::TriggerKind "skill").
  # Resolves the named skill via Skills.for (repo-local override, else
  # built-in), renders its instructions with the Job's supplied args
  # (Prompts::Skill / Skills::Renderer), and invokes the Workflow's
  # configured agent provider the same way Implement does: commit
  # locally, verify branch history, capture the diff.
  #
  # Records which tier resolved (skill_source) and the resolved
  # path/class onto the Run — the EPIC-233 provenance requirement, so a
  # repo-local skill silently shadowing a built-in of the same name is
  # never a debugging trap.
  #
  # No diff is a valid, successful outcome (e.g. a read-only `investigate`
  # skill, or an operational skill that only reports): like Implement,
  # perform_agentic_change_step raises NoChangesProduced when the agent
  # commits nothing. That fails this step and the workflow, but
  # Workflow#propagate_fail_to_job! treats that specific failure as the
  # same no_changes happy path already established for cron Jobs —
  # summarize/pr_open never run and the Job closes successfully.
  class RunSkill < Base
    def call
      # Set up the workspace before resolving — a built-in skill's
      # `.definition` may want a real on-disk checkout to tailor its
      # instructions to (see Skills::OnboardToSyrus). Idempotent:
      # perform_agentic_change_step calls workspace.setup again below,
      # which is a no-op once the clone already exists.
      workspace.setup
      resolution = resolve_skill!
      record_provenance!(resolution)

      perform_agentic_change_step(
        log_message: "invoking agent for run_skill step (#{workflow.slug}, skill=#{skill_name.inspect}, source=#{resolution.source})",
        commit_message: "Syrus skill run: #{skill_name} (will be rewritten by summarize)"
      ) do
        persist_prompt_if_needed(resolution)
      end
    end

    private

    def skill_name
      workflow.artifact("skill_name").to_s
    end

    def skill_args
      workflow.artifact("skill_args") || {}
    end

    def resolve_skill!
      Skills.for(repository: repository, name: skill_name, user: job.user, workspace_path: workspace.path.to_s)
    rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
      raise StepFailed, "could not resolve skill #{skill_name.inspect}: #{e.class}: #{e.message}"
    end

    def record_provenance!(resolution)
      run.update!(
        skill_source: resolution.source.to_s,
        skill_resolved_path: resolution.path,
        skill_resolved_class: resolution.klass&.name
      )
    end

    def persist_prompt_if_needed(resolution)
      return if run.prompt.present?

      Skills::ParameterSchema.validate!(resolution.definition.parameters, skill_args)
      run.update!(prompt: skill_prompt(resolution.definition))
    rescue Skills::ParameterSchema::ValidationError => e
      raise StepFailed, "skill #{skill_name.inspect} args invalid: #{e.message}"
    end

    def skill_prompt(definition)
      Prompts::Skill.new(
        definition: definition,
        args: skill_args,
        epic: job.epic,
        job: job,
        user: job.user,
        repository_ids: [ repository.id ]
      ).to_s
    end
  end
end
