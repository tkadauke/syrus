class NotificationService
  SIMPLE_SUPPRESSED_KINDS = %w[
    job_failed job_implemented pr_comment_addressed pr_merged epic_completed upstream_pr_closed
    main_broken main_inconclusive main_recovered
  ].freeze

  def self.create_for(user:, kind:, job: nil, pr_url: nil, body:)
    raise ArgumentError, "unknown notification kind: #{kind}" unless Notification::KINDS.include?(kind)
    return nil unless user&.id && User.exists?(user.id)
    return nil if AppSetting.simple? && SIMPLE_SUPPRESSED_KINDS.include?(kind)
    return nil unless user.notification_preference_for(kind)

    job = nil if AppSetting.simple?
    pr_url = nil if AppSetting.simple?
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
end
