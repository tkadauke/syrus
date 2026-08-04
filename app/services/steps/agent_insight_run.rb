module Steps
  # Agentic step of AgentInsight workflows. Sets up the workspace so the
  # agent can read the codebase, then invokes the agent with the insight
  # prompt. The agent calls `submit_insight` for each finding and
  # `write_memory` for durable facts.
  #
  # Unlike Implement, this step does NOT commit changes — the insight agent
  # is read-only. No diff is captured; `auto_close` follows on success.
  class AgentInsightRun < Base
    KNOWN_PENDING_INSIGHT_LIMIT = 50
    KNOWN_RESOLVED_INSIGHT_LIMIT = 25
    RECENT_JOB_LIMIT = 50
    FALLBACK_ANALYSIS_WINDOW = 14.days
    EXCLUDED_RECENT_JOB_KINDS = %w[ agent_insight main_grader ].freeze

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
      prior_job = repository.jobs
                             .where(kind: "agent_insight")
                             .where.not(id: job.id)
                             .where.not(finished_at: nil)
                             .order(finished_at: :desc)
                             .first
      analysis_window_start = prior_job&.finished_at
      recent_jobs = recent_jobs_since(analysis_window_start || FALLBACK_ANALYSIS_WINDOW.ago)

      known_insights = known_insights_for_prompt

      Prompts::AgentInsight.new(
        repository: repository,
        recent_jobs: recent_jobs,
        analysis_window_start: analysis_window_start,
        known_insights: known_insights,
        user: job.user
      ).to_s
    end

    def known_insights_for_prompt
      [
        *repository.insight_suggestions.pending.order(updated_at: :desc).limit(KNOWN_PENDING_INSIGHT_LIMIT),
        *repository.insight_suggestions.accepted.order(updated_at: :desc).limit(KNOWN_RESOLVED_INSIGHT_LIMIT),
        *repository.insight_suggestions.dismissed.order(updated_at: :desc).limit(KNOWN_RESOLVED_INSIGHT_LIMIT)
      ].sort_by(&:updated_at).reverse
    end

    def recent_jobs_since(window_start)
      jobs = repository.jobs
                       .closed_threads
                       .where.not(kind: EXCLUDED_RECENT_JOB_KINDS)
                       .where(<<~SQL.squish, window_start: window_start)
                         jobs.finished_at >= :window_start
                         OR EXISTS (
                           SELECT 1 FROM workflows
                           WHERE workflows.job_id = jobs.id
                             AND workflows.finished_at >= :window_start
                         )
                       SQL
                       .includes(workflows: { steps: :runs })

      jobs.reject(&:infrastructure?)
          .sort_by { |recent_job| recent_completion_at(recent_job) || Time.zone.at(0) }
          .reverse
          .first(RECENT_JOB_LIMIT)
    end

    def recent_completion_at(recent_job)
      workflow_finished_at = recent_job.workflows.map(&:finished_at).compact.max
      [ recent_job.finished_at, workflow_finished_at ].compact.max
    end
  end
end
