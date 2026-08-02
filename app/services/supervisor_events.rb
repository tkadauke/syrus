class SupervisorEvents
  SEVERITIES = %w[info warning critical].freeze

  class << self
    def publish!(kind:, severity:, subject:, repository: nil, job: nil, epic: nil, proposal: nil, workflow: nil, run: nil, pr_number: nil, actor: nil, summary:, details: nil, dedupe_key: nil)
      return [] unless Feature.admin_supervisor_chat_enabled?

      recipients = ChatScopedEventRecipients.new(
        repository: repository,
        job: job,
        epic: epic,
        proposal: proposal,
        workflow: workflow,
        run: run,
        pr_number: pr_number,
        details: details
      )

      event = normalize_event(
        kind: kind,
        severity: severity,
        subject: subject,
        repository: recipients.repository,
        actor: actor,
        summary: summary,
        details: details,
        dedupe_key: dedupe_key
      )

      supervisor_events = User.where(admin: true).find_each.filter_map do |admin|
        chat = SupervisorChat.ensure_for!(admin)
        publish_for_chat!(
          chat,
          event,
          repository: recipients.repository,
          job: recipients.job,
          epic: recipients.epic,
          proposal: recipients.proposal,
          changed_marker: "supervisor_event"
        )
      end

      scoped_chat_events = recipients.chat_sessions.filter_map do |chat|
        publish_for_chat!(
          chat,
          event,
          repository: recipients.repository,
          job: recipients.job,
          epic: recipients.epic,
          proposal: recipients.proposal,
          changed_marker: "scoped_event"
        )
      end

      supervisor_events + scoped_chat_events
    end

    private

    def publish_for_chat!(chat, event, repository:, job:, epic:, proposal:, changed_marker:)
      scoped_event = nil
      created = false
      now = Time.current
      ChatSession.transaction(requires_new: true) do
        scoped_event = ChatScopedEvent.record!(
          chat_session: chat,
          source_kind: event.fetch("kind"),
          payload: event.merge("occurred_at" => now.iso8601),
          repository: repository || job&.repository,
          job: job,
          epic: epic,
          proposal: proposal,
          dedupe_key: event["dedupe_key"]
        )
        created = scoped_event.previously_new_record?
        chat.update!(last_message_at: now, last_read_at: nil) if created
      end
      return unless created

      AppEvents.broadcast(
        user: chat.user,
        type: "updated",
        resource: "chat",
        id: chat.id,
        changed: [ "last_message_at", "last_read_at", changed_marker ]
      )
      ChatScopedEventEvaluatorJob.perform_later(scoped_event.id, chat.id)

      scoped_event
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
