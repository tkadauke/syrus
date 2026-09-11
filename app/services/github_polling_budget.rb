class GithubPollingBudget
  BASE_TICK_SECONDS = 5.minutes.to_i
  PR_FEEDBACK_LIMIT = 40
  MERGE_STATE_LIMIT = 60
  EXTERNAL_PR_LIMIT = 30
  FORK_REVIEW_LIMIT = 20

  class << self
    def ordered_jobs(scope)
      scope.order(Arel.sql(<<~SQL.squish), updated_at: :desc, id: :asc)
        CASE
          WHEN jobs.state = 'landing' THEN 0
          WHEN jobs.state = 'approved' THEN 1
          WHEN jobs.state = 'running' THEN 2
          WHEN jobs.state = 'failed' THEN 3
          WHEN jobs.state = 'implemented' THEN 4
          ELSE 5
        END
      SQL
    end

    def take_pollable_jobs(scope, kind:, limit:, now: Time.current)
      selected = []
      ordered_jobs(scope).each do |job|
        next unless poll_job_now?(job, kind: kind, now: now)

        selected << job
        break if selected.size >= limit
      end
      selected
    end

    def poll_job_now?(job, kind:, now: Time.current)
      return true if urgent?(job)
      return true if job.updated_at && job.updated_at > now - 30.minutes

      slots = [ interval_for(kind).to_i / BASE_TICK_SECONDS, 1 ].max
      ((now.to_i / BASE_TICK_SECONDS) % slots) == (job.id % slots)
    end

    private

    def urgent?(job)
      job.landing? || job.approved? || job.running?
    end

    def interval_for(kind)
      case kind.to_sym
      when :pr_feedback then 30.minutes
      when :merge_state then 15.minutes
      when :external_pr, :fork_review then 15.minutes
      else 30.minutes
      end
    end
  end
end
