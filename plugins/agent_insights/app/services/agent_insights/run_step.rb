module AgentInsights
  # Agentic step of AgentInsight workflows. Sets up the workspace so the
  # agent can read the codebase, then invokes the agent with the insight
  # prompt. The agent calls `submit_insight` for each finding and
  # `write_memory` for durable facts.
  #
  # Unlike Implement, this step does NOT commit changes — the insight agent
  # is read-only. No diff is captured; `auto_close` follows on success.
  class RunStep < ::Steps::Base
    KNOWN_PENDING_INSIGHT_LIMIT = 50
    KNOWN_RESOLVED_INSIGHT_LIMIT = 25
    RECENT_JOB_LIMIT = 50
    # Infrastructure jobs are dropped after loading (Job#infrastructure? reads
    # the latest workflow), so fetch some spare candidates.
    RECENT_JOB_CANDIDATES = RECENT_JOB_LIMIT * 2
    LATEST_WORKFLOW_FINISH_SQL = "(SELECT MAX(workflows.finished_at) FROM workflows WHERE workflows.job_id = jobs.id)".freeze
    # When the job finished or its latest workflow did, whichever is later --
    # the same recency the prompt ranks by. CASE rather than GREATEST, which
    # SQLite lacks.
    RECENT_COMPLETION_SQL = <<~SQL.squish.freeze
      CASE WHEN #{LATEST_WORKFLOW_FINISH_SQL} IS NULL OR jobs.finished_at >= #{LATEST_WORKFLOW_FINISH_SQL}
      THEN jobs.finished_at ELSE #{LATEST_WORKFLOW_FINISH_SQL} END
    SQL
    FALLBACK_ANALYSIS_WINDOW = 14.days
    EXCLUDED_RECENT_JOB_KINDS = %w[ agent_insight main_grader deploy ].freeze

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

      Prompt.new(
        repository: repository,
        recent_jobs: recent_jobs,
        analysis_window_start: analysis_window_start,
        known_insights: known_insights,
        user: job.user
      ).to_s
    end

    def known_insights_for_prompt
      [
        *AgentInsights::Suggestion.for_repository(repository).pending.order(updated_at: :desc).limit(KNOWN_PENDING_INSIGHT_LIMIT),
        *AgentInsights::Suggestion.for_repository(repository).accepted.order(updated_at: :desc).limit(KNOWN_RESOLVED_INSIGHT_LIMIT),
        *AgentInsights::Suggestion.for_repository(repository).dismissed.order(updated_at: :desc).limit(KNOWN_RESOLVED_INSIGHT_LIMIT)
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
                       # Rank and cap in SQL, then load history only for those.
                       # Loading every job in the window first -- each with its
                       # workflows, steps (grader output) and runs (full prompts)
                       # -- and keeping 50 afterwards ran an insight past its
                       # pod's 16Gi memory limit, OOM-killing every run on that
                       # compute worker; a failed insight never moves the window,
                       # so each retry loaded more.
                       .reorder(Arel.sql("#{RECENT_COMPLETION_SQL} DESC, jobs.id DESC"))
                       .limit(RECENT_JOB_CANDIDATES)
                       .to_a
      preload_workflows_steps_and_runs(jobs)

      jobs.reject(&:infrastructure?)
          .sort_by { |recent_job| recent_completion_at(recent_job) || Time.zone.at(0) }
          .reverse
          .first(RECENT_JOB_LIMIT)
    end

    # `includes(workflows: { steps: :runs })` preloads three ordered
    # associations across IN lists of ids, which no index can sort: MySQL
    # filesorted every workflow, step (grader output in `details`) and run (the
    # full prompt) of the analysis window, and every insight run failed with
    # `Out of sort memory`. Load them unsorted and order them in Ruby.
    def preload_workflows_steps_and_runs(jobs)
      return if jobs.empty?

      workflows_by_job_id = ::Workflow.where(job_id: jobs.map(&:id)).reorder(nil).to_a.group_by(&:job_id)
      jobs.each do |recent_job|
        attach!(recent_job, :workflows, workflows_by_job_id.fetch(recent_job.id, []).sort_by { |workflow| [ workflow.created_at, workflow.id ] })
      end

      # Done here rather than through core's internal step preloader: a plugin
      # may only reach core through the declared host surface.
      #
      # Only each job's latest workflow is summarised, and only by step kind and
      # run id/state. Loading every workflow's steps (grader output in
      # `details`) and runs (full prompts) for a hundred jobs -- trains alone
      # carry hundreds of grader steps each -- ran an insight past its pod's
      # 16Gi limit within a minute, OOM-killing every run on that worker.
      latest_workflows = jobs.filter_map(&:latest_workflow)
      steps_by_workflow_id = ::Step.where(workflow_id: latest_workflows.map(&:id))
        .select(:id, :workflow_id, :kind, :position).reorder(nil).to_a.group_by(&:workflow_id)
      latest_workflows.each do |workflow|
        ordered = steps_by_workflow_id.fetch(workflow.id, []).sort_by { |step| [ step.position, step.id ] }
        ordered.each { |step| step.association(:workflow).target = workflow }
        attach!(workflow, :steps, ordered)
      end
      steps = latest_workflows.flat_map(&:steps)
      return if steps.empty?

      steps_by_id = steps.index_by(&:id)
      runs_by_step_id = Run.where(step_id: steps_by_id.keys)
        .select(:id, :step_id, :state, :created_at).reorder(nil).to_a.group_by(&:step_id)
      steps.each do |step|
        ordered = runs_by_step_id.fetch(step.id, []).sort_by { |run| [ run.created_at, run.id ] }
        ordered.each { |run| run.association(:step).target = step }
        attach!(step, :runs, ordered)
      end
    end

    def attach!(owner, name, records)
      association = owner.association(name)
      association.target = records
      association.loaded!
    end

    def recent_completion_at(recent_job)
      workflow_finished_at = recent_job.workflows.map(&:finished_at).compact.max
      [ recent_job.finished_at, workflow_finished_at ].compact.max
    end
  end
end
