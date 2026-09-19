require "digest"

class NotificationService
  def self.create_for(user:, kind:, job: nil, repository: nil, actor: nil, pr_url: nil, body:, chat_work_event_dedupe_key: nil)
    raise ArgumentError, "unknown notification kind: #{kind}" unless Notification::KINDS.include?(kind)
    return nil unless user&.id && User.exists?(user.id)

    publish_chat_work_event(
      user: user,
      kind: kind,
      job: job,
      repository: repository,
      actor: actor,
      pr_url: pr_url,
      body: body,
      dedupe_key: chat_work_event_dedupe_key
    )

    return nil unless user.notification_preference_for(kind)

    notification = Notification.create!(
      user: user,
      kind: kind,
      job: job,
      pr_url: pr_url,
      body: body
    )

    ActionCable.server.broadcast(
      AppUserChannel.broadcasting_for(user),
      {
        type: "notification_created",
        unread_count: user.notifications.unread.count,
        payload: {
          unread_count: user.notifications.unread.count,
          notification: notification_payload(notification)
        }
      }
    )

    notification
  end

  def self.notification_payload(notification)
    {
      id: notification.id,
      kind: notification.kind,
      body: notification.body,
      read_at: notification.read_at&.iso8601,
      pr_url: notification.pr_url,
      job_id: notification.job_id,
      job_title: notification.job&.title,
      created_at: notification.created_at.iso8601
    }
  end

  # workflow-engine-v3 B2: chat work events are not a notification firehose.
  #
  # Every notification used to become a chat work event, which is why the
  # old admin Supervisor chat drowned: most notifications report that
  # something *went fine*, and a queue of those buries the rare one that
  # needs a decision.
  #
  # Failure/attention kinds always publish -- they always warrant judgment.
  # Success-completion kinds also publish now, but only wake a chat when the
  # evaluator (see ChatEventEvaluator) finds transcript evidence the operator
  # actually cares about that specific outcome; routine progress kinds that
  # are neither a failure nor a real completion (a feedback round queued, an
  # external reviewer left a comment, PR feedback addressed) stay out of the
  # event pipeline entirely -- they are still notifications, the user sees
  # them, they just do not wake a scoped chat.
  CHAT_WORK_EVENT_KINDS = %w[
    job_failed main_broken main_inconclusive upstream_pr_closed
    job_implemented pr_merged epic_completed main_recovered
  ].freeze

  def self.chat_work_event_kind?(kind) = CHAT_WORK_EVENT_KINDS.include?(kind.to_s)
  private_class_method :chat_work_event_kind?

  def self.publish_chat_work_event(user:, kind:, job:, repository:, actor:, pr_url:, body:, dedupe_key:)
    return unless chat_work_event_kind?(kind)

    ChatWorkEvents.publish!(
      kind: kind,
      severity: severity_for(kind),
      subject: subject_for(kind, job),
      repository: repository || job&.repository,
      job: job,
      actor: actor || user,
      summary: body,
      details: { "notification_kind" => kind, "job_id" => job&.id, "pr_url" => pr_url }.compact,
      dedupe_key: dedupe_key || default_dedupe_key(kind, job, repository, body)
    )
  end
  private_class_method :publish_chat_work_event

  def self.subject_for(kind, job)
    return "#{job.slug}: #{kind.to_s.humanize}" if job

    kind.to_s.humanize
  end
  private_class_method :subject_for

  def self.severity_for(kind)
    case kind.to_s
    when "job_failed", "main_broken" then "critical"
    when "main_inconclusive", "upstream_pr_closed" then "warning"
    else "info"
    end
  end
  private_class_method :severity_for

  def self.default_dedupe_key(kind, job, repository, body)
    if job
      "notification:#{kind}:job:#{job.id}:#{job.updated_at.to_i}"
    else
      repository_id = repository&.id || "none"
      "notification:#{kind}:repository:#{repository_id}:#{Digest::SHA256.hexdigest(body.to_s)[0, 16]}"
    end
  end
  private_class_method :default_dedupe_key
end
