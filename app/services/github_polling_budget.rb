class GithubPollingBudget
  BASE_TICK_SECONDS = 5.minutes.to_i
  PR_FEEDBACK_LIMIT = 40
  MERGE_STATE_LIMIT = 60
  EXTERNAL_PR_LIMIT = 30
  FORK_REVIEW_LIMIT = 20

  # Merge-state polling only needs full-cadence, every-tick attention for
  # Jobs actively moving toward or through landing -- everything else
  # (running, failed, blocked_by_epic, implemented, ...) falls back to
  # the recent-update fast path in `poll_job_now?` plus the periodic
  # low-frequency rotation, which still guarantees Syrus eventually
  # notices an externally merged/closed PR (there are no inbound
  # GitHub callbacks). Other polling kinds (pr_feedback, external_pr,
  # fork_review) keep treating `running` as urgent -- those cover PR
  # comment/close discovery, which stays relevant while a Job is
  # actively being worked.
  MERGE_STATE_URGENT_STATES = %w[ landing approved ].freeze
  DEFAULT_URGENT_STATES = %w[ landing approved running ].freeze

  class PollingKind
    class << self
      def for(kind)
        REGISTRY.fetch(kind.to_sym, DEFAULT)
      end
    end

    def interval = 30.minutes
    def urgent_states = DEFAULT_URGENT_STATES
  end

  class Default < PollingKind
  end

  class PullRequestFeedback < PollingKind
    def self.kind = :pr_feedback
  end

  class MergeState < PollingKind
    def self.kind = :merge_state
    def interval = 15.minutes
    def urgent_states = MERGE_STATE_URGENT_STATES
  end

  class ExternalPullRequest < PollingKind
    def self.kind = :external_pr
    def interval = 15.minutes
  end

  class ForkReview < PollingKind
    def self.kind = :fork_review
    def interval = 15.minutes
  end

  DEFAULT = Default.new
  REGISTRY = [
    PullRequestFeedback,
    MergeState,
    ExternalPullRequest,
    ForkReview
  ].to_h { |klass| [ klass.kind, klass.new ] }.freeze

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
      return true if urgent?(job, kind: kind)
      return true if job.updated_at && job.updated_at > now - 30.minutes

      slots = [ interval_for(kind).to_i / BASE_TICK_SECONDS, 1 ].max
      ((now.to_i / BASE_TICK_SECONDS) % slots) == (job.id % slots)
    end

    private

    def urgent?(job, kind:)
      polling_kind_for(kind).urgent_states.include?(job.state)
    end

    def urgent_states_for(kind)
      polling_kind_for(kind).urgent_states
    end

    def interval_for(kind)
      polling_kind_for(kind).interval
    end

    def polling_kind_for(kind)
      PollingKind.for(kind)
    end
  end
end
