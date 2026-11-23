# Fans a Notification out to the user's registered native devices over APNs.
# Enqueued from NotificationService only when the user has an active device and
# APNs credentials are configured, so unconfigured instances do no extra work.
class PushNotificationDeliveryJob < ApplicationJob
  queue_as :control_plane

  retry_on PushNotifications::Deliverer::RetryableDeliveryError, wait: :polynomially_longer, attempts: 5

  def self.enqueue_for(notification)
    return unless PushNotifications::ApnsConfig.from_env.configured?
    return unless notification.user.push_devices.active.exists?

    perform_later(notification.id)
  end

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification

    PushNotifications::Deliverer.new.deliver(notification)
  end
end
