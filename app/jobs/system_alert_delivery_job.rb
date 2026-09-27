class SystemAlertDeliveryJob < ApplicationJob
  queue_as :control_plane

  limits_concurrency to: 1, key: "system_alert_delivery", duration: 5.minutes, on_conflict: :discard

  def perform
    return unless SystemAlertDelivery.configured?

    SystemAlertDelivery.deliver(SystemAlerts.outbound_alerts)
  end
end
