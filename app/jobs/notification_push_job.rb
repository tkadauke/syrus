# Delivers a Notification to the user's registered native devices.
class NotificationPushJob < ApplicationJob
  queue_as :control_plane

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification

    Push::NotificationDelivery.new(notification).deliver
  end
end
