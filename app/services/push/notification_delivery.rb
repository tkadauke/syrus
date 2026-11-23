module Push
  # Pushes one Notification to each of its user's active devices and retires
  # tokens APNs reports as dead.
  class NotificationDelivery
    def initialize(notification, client: ApnsClient.new)
      @notification = notification
      @client = client
    end

    def deliver
      return 0 unless @client.configured?

      @notification.user.push_devices.active.map { |device| deliver_to(device) }.count(true)
    end

    private

    def deliver_to(device)
      response = @client.deliver(
        device: device,
        alert: { "title" => title, "body" => @notification.body.to_s.truncate(200) },
        payload: { notification_id: @notification.id, kind: @notification.kind, target_path: @notification.target_path },
        collapse_id: "notification-#{@notification.id}"
      )
      device.disable!(response.reason.presence || "invalid_token") if response.invalid_token?
      Rails.logger.warn("[Push] APNs rejected device #{device.id}: #{response.status} #{response.reason}") unless response.success? || response.invalid_token?
      response.success?
    rescue StandardError => e
      Rails.logger.warn("[Push] delivery to device #{device.id} failed: #{e.class}: #{e.message}")
      false
    end

    def title = @notification.job&.title.presence || "Syrus"
  end
end
