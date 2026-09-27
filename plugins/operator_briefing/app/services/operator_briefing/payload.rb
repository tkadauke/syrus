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
        source_preferences: source_preferences_payload,
        source_preference_suggestions: source_preference_suggestions_payload,
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

    def source_preferences_payload
      OperatorBriefing::SourcePreference.effective_for_user(user).values.map do |preference|
        source_preference_payload(preference)
      end.sort_by { |row| row[:label] }
    end

    def source_preference_suggestions_payload
      OperatorBriefing::SourcePreference.pending_for_user(user).map do |preference|
        source_preference_payload(preference)
      end
    end

    def source_preference_payload(preference)
      source = preference.source_definition || {}
      {
        id: preference.id,
        source_key: preference.source_key,
        label: source[:label] || preference.source_key.humanize,
        description: source[:description],
        enabled: preference.enabled?,
        weight: preference.weight,
        suggested_by: preference.suggested_by,
        confirmed_at: preference.confirmed_at&.iso8601,
        pending: preference.confirmed_at.blank?
      }
    end

    def repository_payloads
      enabled_subscriptions.map do |subscription|
        repository = subscription.repository
        current = current_briefings[repository.id]
        {
          repository: repository_payload(repository),
          current: briefing_payload(current),
          history: history_payload(repository),
          status: status_payload(repository, current)
        }
      end
    end

    def enabled_subscriptions
      @enabled_subscriptions ||= subscriptions.select(&:enabled?)
    end

    def enabled_repository_ids
      @enabled_repository_ids ||= enabled_subscriptions.map(&:repository_id)
    end

    def repository_payload(repository)
      {
        id: repository.id,
        slug: repository.slug,
        path: "/repositories/#{repository.id}"
      }
    end

    def current_briefings
      @current_briefings ||= Briefing
        .joins(:job)
        .where(owner_user: user, repository_id: enabled_repository_ids)
        .where.not(jobs: { state: Job::TERMINAL_STATES })
        .includes(:job)
        .order(created_at: :desc, id: :desc)
        .each_with_object({}) do |briefing, index|
          index[briefing.repository_id] ||= briefing
        end
    end

    def history_briefings
      @history_briefings ||= Briefing
        .joins(:job)
        .where(owner_user: user, repository_id: enabled_repository_ids, jobs: { state: "closed" })
        .includes(:job)
        .order(created_at: :desc, id: :desc)
        .group_by(&:repository_id)
        .transform_values { |briefings| briefings.first(HISTORY_LIMIT) }
    end

    def all_serialized_briefings
      @all_serialized_briefings ||= current_briefings.values + history_briefings.values.flatten
    end

    def latest_revisions
      @latest_revisions ||= begin
        briefing_ids = all_serialized_briefings.map(&:id)
        if briefing_ids.empty?
          {}
        else
          BriefingRevision
            .where(briefing_id: briefing_ids)
            .order(revision_number: :desc, id: :desc)
            .each_with_object({}) do |revision, index|
              index[revision.briefing_id] ||= revision
            end
        end
      end
    end

    def history_payload(repository)
      history_briefings.fetch(repository.id, [])
        .map { |briefing| briefing_payload(briefing) }
    end

    def briefing_payload(briefing)
      return nil unless briefing

      revision = latest_revisions[briefing.id]
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
      if generator.activity_since_last_generation?
        { kind: "ready", message: "Activity is available for the next scheduled briefing." }
      else
        { kind: "no_activity", message: "No briefing generated because nothing changed since the last closed briefing." }
      end
    end
  end
end
