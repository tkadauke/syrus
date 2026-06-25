class NotificationService
  def self.create_for(user:, kind:, job: nil, pr_url: nil, body:)
    raise ArgumentError, "unknown notification kind: #{kind}" unless Notification::KINDS.include?(kind)
    return nil unless user&.id && User.exists?(user.id)

    Notification.create!(
      user: user,
      kind: kind,
      job: job,
      pr_url: pr_url,
      body: body
    )
  end
end
