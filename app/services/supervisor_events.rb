class SupervisorEvents
  SEVERITIES = %w[info warning critical].freeze
  DEDUPE_LOOKBACK = 24.hours

  class << self
    def publish!(kind:, severity:, subject:, repository: nil, actor: nil, summary:, details: nil, dedupe_key: nil)
      return [] unless Feature.admin_supervisor_chat_enabled?

      event = normalize_event(
        kind: kind,
        severity: severity,
        subject: subject,
        repository: repository,
        actor: actor,
        summary: summary,
        details: details,
        dedupe_key: dedupe_key
      )

      User.where(admin: true).find_each.filter_map do |admin|
        publish_for_admin!(admin, event)
      end
    end

    private

    def publish_for_admin!(admin, event)
      chat = SupervisorChat.ensure_for!(admin)
      return if duplicate?(chat, event["dedupe_key"])

      message = nil
      now = Time.current
      ChatSession.transaction(requires_new: true) do
        message = chat.messages.create!(
          role: "system",
          content: {
            "text" => message_text(event),
            "supervisor_event" => event.merge("occurred_at" => now.iso8601)
          }
        )
        chat.update!(last_message_at: now, last_read_at: nil)
      end

      AppEvents.broadcast(
        user: admin,
        type: "updated",
        resource: "chat",
        id: chat.id,
        changed: [ "last_message_at", "last_read_at", "supervisor_event" ]
      )

      message
    end

    def duplicate?(chat, dedupe_key)
      return false if dedupe_key.blank?

      chat.messages
        .where(role: "system")
        .where("created_at >= ?", DEDUPE_LOOKBACK.ago)
        .order(created_at: :desc, id: :desc)
        .limit(200)
        .any? do |message|
          content = message.content
          content.is_a?(Hash) &&
            content.dig("supervisor_event", "dedupe_key").to_s == dedupe_key.to_s
        end
    end

    def normalize_event(kind:, severity:, subject:, repository:, actor:, summary:, details:, dedupe_key:)
      kind_s = kind.to_s.strip
      severity_s = severity.to_s.strip
      subject_s = subject.to_s.strip
      summary_s = summary.to_s.strip

      raise ArgumentError, "kind is required" if kind_s.blank?
      raise ArgumentError, "subject is required" if subject_s.blank?
      raise ArgumentError, "summary is required" if summary_s.blank?
      raise ArgumentError, "unknown supervisor event severity: #{severity}" unless SEVERITIES.include?(severity_s)

      {
        "kind" => kind_s,
        "severity" => severity_s,
        "subject" => subject_s,
        "summary" => summary_s,
        "details" => details.presence,
        "repository" => repository_json(repository),
        "actor" => actor_json(actor),
        "dedupe_key" => dedupe_key.to_s.presence
      }.compact
    end

    def message_text(event)
      repository = event.dig("repository", "slug")
      suffix = repository.present? ? " (#{repository})" : nil
      "[#{event.fetch("severity").upcase}] #{event.fetch("subject")}#{suffix}\n#{event.fetch("summary")}"
    end

    def repository_json(repository)
      return unless repository

      {
        "id" => repository.id,
        "slug" => repository.slug
      }
    end

    def actor_json(actor)
      return unless actor

      if actor.respond_to?(:display_name)
        {
          "type" => actor.class.name,
          "id" => actor.id,
          "display_name" => actor.display_name
        }
      elsif actor.respond_to?(:id)
        {
          "type" => actor.class.name,
          "id" => actor.id
        }
      else
        {
          "type" => actor.class.name,
          "label" => actor.to_s
        }
      end
    end
  end
end
