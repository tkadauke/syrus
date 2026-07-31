require "digest"

class NotificationService
  def self.create_for(user:, kind:, job: nil, repository: nil, actor: nil, pr_url: nil, body:, supervisor_dedupe_key: nil)
    raise ArgumentError, "unknown notification kind: #{kind}" unless Notification::KINDS.include?(kind)
    return nil unless user&.id && User.exists?(user.id)

    publish_supervisor_event(
      user: user,
      kind: kind,
      job: job,
      repository: repository,
      actor: actor,
      pr_url: pr_url,
      body: body,
      dedupe_key: supervisor_dedupe_key
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
      { type: "notification_created", unread_count: user.notifications.unread.count }
    )

    notification
  end

  def self.publish_supervisor_event(user:, kind:, job:, repository:, actor:, pr_url:, body:, dedupe_key:)
    SupervisorEvents.publish!(
      kind: kind,
      severity: severity_for(kind),
      subject: subject_for(kind, job),
      repository: repository || job&.repository,
      actor: actor || user,
      summary: body,
      details: { "notification_kind" => kind, "job_id" => job&.id, "pr_url" => pr_url }.compact,
      dedupe_key: dedupe_key || default_dedupe_key(kind, job, repository, body)
    )
  end
  private_class_method :publish_supervisor_event

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
