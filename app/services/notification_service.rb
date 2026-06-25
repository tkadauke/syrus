class NotificationService
  def self.create_for(user:, kind:, job: nil, pr_url: nil, body:)
    raise ArgumentError, "unknown notification kind: #{kind}" unless Notification::KINDS.include?(kind)
    return nil unless user&.id && User.exists?(user.id)
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
end
