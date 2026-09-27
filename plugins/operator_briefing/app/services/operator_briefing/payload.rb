module OperatorBriefing
  class Payload
    HISTORY_LIMIT = 10

    def initialize(user:)
      @user = user
    end

    def as_json(*)
      BriefingSubscription.seed_for_user!(user)

      {
        settings: settings_payload,
        repositories: repository_payloads,
        subscriptions: subscriptions_payload,
        generated_at: Time.current.iso8601
      }
    end

    private

    attr_reader :user

    def settings
      @settings ||= BriefingSettings.for_user(user)
    end

    def settings_payload
      {
        cadence_expression: settings.cadence_expression,
        budget_check_enabled: settings.budget_check_enabled?,
        agent_provider: settings.agent_provider,
        last_scheduled_at: settings.last_scheduled_at&.iso8601,
        budget_gate: BudgetGate.evaluate(settings).to_h
      }
    end

    def subscriptions
      @subscriptions ||= BriefingSubscription
        .where(user: user, repository_id: Repository.accessible_repository_ids_for(user))
        .includes(:repository)
        .order("repositories.owner ASC", "repositories.name ASC", :id)
        .references(:repository)
        .to_a
    end

    def subscriptions_payload
      subscriptions.map do |subscription|
        repository = subscription.repository
        {
          id: subscription.id,
          enabled: subscription.enabled?,
          repository: repository_payload(repository)
        }
      end
    end

    def repository_payloads
      subscriptions.select(&:enabled?).map do |subscription|
        repository = subscription.repository
        current = current_briefing(repository)
        {
          repository: repository_payload(repository),
          current: briefing_payload(current),
          history: history_payload(repository, current),
          status: status_payload(repository, current)
        }
      end
    end

    def repository_payload(repository)
      {
        id: repository.id,
        slug: repository.slug,
        path: "/repositories/#{repository.id}"
      }
    end

    def current_briefing(repository)
      Briefing
        .joins(:job)
        .where(owner_user: user, repository: repository)
        .where.not(jobs: { state: Job::TERMINAL_STATES })
        .includes(:job, :revisions)
        .order(created_at: :desc, id: :desc)
        .first
    end

    def history_payload(repository, current)
      Briefing
        .joins(:job)
        .where(owner_user: user, repository: repository, jobs: { state: "closed" })
        .where.not(id: current&.id)
        .includes(:job, :revisions)
        .order(created_at: :desc, id: :desc)
        .limit(HISTORY_LIMIT)
        .map { |briefing| briefing_payload(briefing) }
    end

    def briefing_payload(briefing)
      return nil unless briefing

      revision = briefing.latest_revision
      {
        id: briefing.id,
        live: briefing.live?,
        window_start: briefing.window_start&.iso8601,
        window_end: briefing.window_end&.iso8601,
        job: job_payload(briefing.job),
        latest_revision: revision && revision_payload(revision)
      }
    end

    def revision_payload(revision)
      {
        id: revision.id,
        revision_number: revision.revision_number,
        generated_at: revision.generated_at&.iso8601,
        content_blocks: revision.content_blocks
      }
    end

    def job_payload(job)
      {
        id: job.id,
        slug: job.slug,
        title: job.issue_title.presence || job.slug,
        state: job.state,
        path: "/jobs/#{job.id}"
      }
    end

    def status_payload(repository, current)
      return { kind: "live", message: nil } if current

      generator = Generator.new(user: user, repository: repository, mode: :scheduled, now: Time.current)
      if generator.activity_since_last_closed?
        { kind: "ready", message: "Activity is available for the next scheduled briefing." }
      else
        { kind: "no_activity", message: "No briefing generated because nothing changed since the last closed briefing." }
      end
    end
  end
end
