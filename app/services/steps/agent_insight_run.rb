module Steps
  # Agentic step of AgentInsight workflows. Sets up the workspace so the
  # agent can read the codebase, then invokes the agent with the insight
  # prompt. The agent calls `submit_insight` for each finding and
  # `write_memory` for durable facts.
  #
  # Unlike Implement, this step does NOT commit changes — the insight agent
  # is read-only. No diff is captured; `auto_close` follows on success.
  class AgentInsightRun < Base
    def call
      workspace.setup
      persist_prompt_if_needed
      log("invoking agent for agent_insight_run step (#{workflow.slug})")
      run_agent(prompt: run.prompt)
    end

    private

    def persist_prompt_if_needed
      return if run.prompt.present?

      run.update!(prompt: insight_prompt)
    end

    def insight_prompt
      recent_jobs = repository.jobs
                               .where(kind: "issue")
                               .where("created_at >= ?", 14.days.ago)
                               .order(created_at: :desc)
                               .limit(50)

      prior_job = repository.jobs
                             .where(kind: "agent_insight")
                             .where.not(id: job.id)
                             .order(created_at: :desc)
                             .first

      known_insights = [
        *repository.insight_suggestions.accepted.order(updated_at: :desc).limit(25),
        *repository.insight_suggestions.dismissed.order(updated_at: :desc).limit(25)
      ]

      Prompts::AgentInsight.new(
        repository: repository,
        recent_jobs: recent_jobs,
        analysis_window_start: prior_job&.finished_at,
        known_insights: known_insights,
        user: job.user
      ).to_s
    end
  end
end
