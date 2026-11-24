module MobileDevices
  # Delivers an in-app Notification to every active mobile device of its user.
  # Called from MobilePushDeliveryJob so APNs latency never blocks the code
  # path that created the notification.
  class PushDelivery
    TITLE = "Syrus".freeze

    def self.client
      @client ||= Apns::Client.new
    end

    # Test seam.
    def self.client=(client)
      @client = client
    end

    def initialize(notification, client: self.class.client)
      @notification = notification
      @client = client
    end

    # Returns the number of devices that accepted the push.
    def call
      return 0 unless @client.configured?

      user = @notification.user
      unread = user.notifications.unread.count
      payload = payload_for(unread)
      delivered = 0

      user.mobile_devices.active.find_each do |device|
        result = @client.deliver(device: device, payload: payload, collapse_id: "notification-#{@notification.id}")
        if result.success?
          device.update_columns(last_delivered_at: Time.current)
          delivered += 1
        elsif result.invalid_token?
          device.disable!(result.reason || "http_#{result.status}")
        else
          Rails.logger.warn("[apns] push to mobile_device=#{device.id} failed: #{result.status} #{result.reason}")
        end
      rescue StandardError => e
        Rails.logger.warn("[apns] push to mobile_device=#{device.id} errored: #{e.class}: #{e.message}")
      end
      delivered
    end

    def payload_for(unread_count)
      {
        aps: {
          alert: { title: TITLE, body: @notification.body },
          badge: unread_count,
          sound: "default",
          "thread-id": (@notification.job_id ? "job-#{@notification.job_id}" : "syrus"),
          "mutable-content": 1
        },
        syrus: {
          notification_id: @notification.id,
          kind: @notification.kind,
          job_id: @notification.job_id,
          target_path: @notification.target_path
        }.compact
      }
    end
  end
end
