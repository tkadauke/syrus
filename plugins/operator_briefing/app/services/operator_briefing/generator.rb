module OperatorBriefing
  class Generator
    FALLBACK_WINDOW = 7.days
    SUPERSEDED_REASON = "briefing_superseded".freeze

    Result = Data.define(:job, :briefing, :status, :reason) do
      def created? = status == "created"
      def skipped? = status == "skipped"
    end

    def self.generate!(user:, repository:, mode: :scheduled, now: Time.current)
      new(user: user, repository: repository, mode: mode, now: now).generate!
    end

    def initialize(user:, repository:, mode:, now:)
      @user = user
      @repository = repository
      @mode = mode.to_sym
      @now = now
    end

    def generate!
      return skipped("no_activity") unless on_demand? || activity_since_last_closed?

      budget = BudgetGate.evaluate(settings)
      return skipped("budget") if scheduled? && budget.skip

      Job.transaction do
        close_current_live_briefings!
        create_briefing_job!
      end
    end

    def activity_since_last_closed?
      ActivityGate.new(user: user, repository: repository, since: last_closed_at).activity?
    end

    def last_closed_at
      @last_closed_at ||= Briefing
        .joins(:job)
        .where(owner_user: user, repository: repository, jobs: { state: "closed" })
        .order(Arel.sql("COALESCE(jobs.finished_at, operator_briefing_briefings.window_end) DESC"), id: :desc)
        .pick(Arel.sql("COALESCE(jobs.finished_at, operator_briefing_briefings.window_end)"))
    end

    private

    attr_reader :user, :repository, :mode, :now

    def scheduled? = mode == :scheduled
    def on_demand? = mode == :on_demand

    def settings
      @settings ||= BriefingSettings.for_user(user)
    end

    def skipped(reason)
      Result.new(job: nil, briefing: nil, status: "skipped", reason: reason)
    end

    def close_current_live_briefings!
      Briefing
        .joins(:job)
        .where(owner_user: user, repository: repository)
        .where.not(jobs: { state: Job::TERMINAL_STATES })
        .includes(:job)
        .find_each do |briefing|
          job = briefing.job
          job.close_with_reason!(SUPERSEDED_REASON) if job.may_close?
        end
    end

    def create_briefing_job!
      job = user.jobs.create!(
        repository: repository,
        kind: "briefing_generate",
        priority: "low",
        issue_number: nil,
        issue_title: "Operator briefing: #{repository.slug}",
        owner_user: user,
        agent_provider: settings.agent_provider.presence || user.agent_provider
      )
      briefing = Briefing.create!(
        job: job,
        repository: repository,
        owner_user: user,
        window_start: last_closed_at || FALLBACK_WINDOW.ago(now),
        window_end: now
      )
      WorkUnits::Launcher.create_and_start!(
        kind: "briefing_generate",
        job: job,
        agent_provider: settings.agent_provider.presence
      )
      Result.new(job: job, briefing: briefing, status: "created", reason: nil)
    end
  end
end
