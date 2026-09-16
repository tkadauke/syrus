module Steps
  # Agentic step of `investigation` Workflows (Workflow::TriggerKind
  # "investigation"). Sets up the workspace so the agent can read the
  # codebase, run tests, or drive a preview, then invokes the agent with
  # the operator-supplied investigation prompt.
  #
  # Unlike Implement/RunSkill, this step never calls perform_agentic_change_step
  # and never captures or requires a diff -- it is read-only, the same as
  # AgentInsights::RunStep. Success is defined by the following
  # submit_report step persisting a narrative report, not by producing a
  # diff, so raise_no_changes_produced! never enters into it.
  class Investigate < Base
    def call
      workspace.setup
      persist_prompt_if_needed
      log("invoking agent for investigate step (#{workflow.slug})")
      run_agent(prompt: run.prompt)
    end

    private

    def persist_prompt_if_needed
      return if run.prompt.present?

      run.update!(prompt: investigation_prompt)
    end

    def investigation_prompt
      Prompts::Investigation.new(
        issue: fetch_issue,
        epic: job.epic,
        job: job,
        user: job.user,
        repository_ids: [ repository.id ]
      ).to_s
    end
  end
end
