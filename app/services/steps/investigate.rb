module Steps
  # Agentic step of `investigation` Workflows (Workflow::TriggerKind
  # "investigation"). Sets up the workspace so the agent can read the
  # codebase, run tests, or drive a preview, then invokes the agent with
  # the operator-supplied investigation prompt built from the resolved
  # `investigate-and-report` skill (repo-local override, else
  # Skills::InvestigateAndReport -- see Skills.for) -- the same
  # resolution shape Steps::RunSkill uses, so a repository can override
  # its own investigation instructions via
  # `.syrus/skills/investigate-and-report/SKILL.md` instead of getting a
  # one-size-fits-all hand-rolled prompt.
  #
  # Unlike Implement/RunSkill, this step never calls perform_agentic_change_step
  # and never captures or requires a diff -- it is read-only, the same as
  # AgentInsights::RunStep. Success is defined by the following
  # submit_report step persisting a narrative report, not by producing a
  # diff, so raise_no_changes_produced! never enters into it.
  class Investigate < Base
    def call
      workspace.setup
      resolution = resolve_skill!
      record_provenance!(resolution)
      persist_prompt_if_needed(resolution)
      log("invoking agent for investigate step (#{workflow.slug}, source=#{resolution.source})")
      run_agent(prompt: run.prompt)
    end

    private

    def resolve_skill!
      Skills.for(repository: repository, name: "investigate-and-report", user: job.user, workspace_path: workspace.path.to_s)
    rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
      raise StepFailed, "could not resolve investigate-and-report skill: #{e.class}: #{e.message}"
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

      run.update!(prompt: investigation_prompt(resolution))
    end

    def investigation_prompt(resolution)
      Prompts::Investigation.new(
        definition: resolution.definition,
        request: fetch_issue.body,
        epic: job.epic,
        job: job,
        user: job.user,
        repository_ids: [ repository.id ]
      ).to_s
    end
  end
end
