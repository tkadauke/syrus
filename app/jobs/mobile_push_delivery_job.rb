class MobilePushDeliveryJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(notification_id)
    MobileDevices::PushDelivery.new(Notification.find(notification_id)).call
  end
end
