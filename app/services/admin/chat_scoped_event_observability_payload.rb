module Admin
  class ChatScopedEventObservabilityPayload
    WINDOW = 24.hours
    RECENT_LIMIT = 10
    FAILURE_LIMIT = 10
    DECISIONS = %w[no_op respond act].freeze

    def as_json(*)
      events = recent_events_relation.to_a
      {
        window_hours: (WINDOW / 1.hour).to_i,
        total: events.size,
        by_state: count_by(events) { |event| event.evaluator_state },
        by_decision: decision_counts(events),
        failures: failure_payload(events),
        recent: recent_payload
      }
    end

    private

    def recent_events_relation
      ChatScopedEvent
        .includes(:chat_session, :repository, :job, :epic, :proposal)
        .where("chat_scoped_events.created_at >= ?", WINDOW.ago)
    end

    def count_by(events)
      events.each_with_object(Hash.new(0)) do |event, counts|
        counts[yield(event).to_s] += 1
      end
    end

    def decision_counts(events)
      counts = DECISIONS.index_with { 0 }
      events.each do |event|
        decision = json_hash(event.evaluator_result)["decision"].to_s
        counts[decision] += 1 if counts.key?(decision)
      end
      counts
    end

    def failure_payload(events)
      events
        .select(&:evaluator_failed?)
        .sort_by { |event| event.evaluated_at || event.updated_at || event.created_at }
        .reverse
        .first(FAILURE_LIMIT)
        .map { |event| event_payload(event).merge("error" => event.evaluator_error.to_s) }
    end

    def recent_payload
      ChatScopedEvent
        .includes(:chat_session, :repository, :job, :epic, :proposal)
        .order(created_at: :desc, id: :desc)
        .limit(RECENT_LIMIT)
        .map { |event| event_payload(event) }
    end

    def event_payload(event)
      payload = json_hash(event.payload)
      result = json_hash(event.evaluator_result)
      {
        "id" => event.id,
        "source_kind" => event.source_kind,
        "summary" => payload["summary"].to_s,
        "severity" => payload["severity"].to_s.presence,
        "delivery_state" => event.delivery_state,
        "evaluator_state" => event.evaluator_state,
        "decision" => result["decision"].to_s.presence,
        "reason" => result["reason"].to_s.presence,
        "dedupe_key" => event.dedupe_key,
        "created_at" => event.created_at&.iso8601,
        "evaluated_at" => event.evaluated_at&.iso8601,
        "chat" => chat_payload(event.chat_session),
        "repository" => repository_payload(event.repository),
        "job" => job_payload(event.job),
        "epic" => epic_payload(event.epic),
        "proposal_id" => event.proposal_id
      }.compact
    end

    def json_hash(value)
      value.is_a?(Hash) ? value : {}
    end

    def chat_payload(chat)
      return unless chat

      {
        "id" => chat.id,
        "title" => chat.title.to_s.presence || "Chat #{chat.id}",
        "system_kind" => chat.system_kind,
        "path" => "/chats/#{chat.id}"
      }.compact
    end

    def repository_payload(repository)
      return unless repository

      {
        "id" => repository.id,
        "slug" => repository.slug
      }
    end

    def job_payload(job)
      return unless job

      {
        "id" => job.id,
        "slug" => "JOB-#{job.id}",
        "path" => "/jobs/#{job.id}"
      }
    end

    def epic_payload(epic)
      return unless epic

      {
        "id" => epic.id,
        "slug" => "EPIC-#{epic.id}",
        "path" => "/epics/#{epic.id}"
      }
    end
  end
end
