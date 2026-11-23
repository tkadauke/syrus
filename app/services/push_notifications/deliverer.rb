module PushNotifications
  # Sends one Notification to every active device its user has registered.
  class Deliverer
    # Raised when at least one device hit a retryable APNs failure so the job
    # layer can back off and retry just that delivery.
    class RetryableDeliveryError < StandardError; end

    def initialize(client: nil, config: ApnsConfig.from_env)
      @config = config
      @client = client || ApnsClient.new(config: config)
    end

    def deliver(notification)
      return 0 unless @config.configured?

      unread = notification.user.notifications.unread.count
      delivered = 0
      retry_needed = false

      notification.user.push_devices.active.ios.find_each do |device|
        result = @client.deliver(
          device_token: device.token,
          environment: device.environment,
          payload: payload_for(notification, unread_count: unread),
          collapse_id: "notification-#{notification.id}"
        )
        if result.success?
          device.update_columns(last_delivered_at: Time.current)
          delivered += 1
        elsif result.unregistered?
          device.disable!(reason: result.reason || "unregistered")
        elsif result.retryable?
          retry_needed = true
        else
          Rails.logger.warn("[push] APNs rejected notification #{notification.id} for device #{device.id}: #{result.status} #{result.reason}")
        end
      end

      raise RetryableDeliveryError, "APNs delivery for notification #{notification.id} needs a retry" if retry_needed && delivered.zero?

      delivered
    end

    # The `syrus` key carries routing data the app uses to open the right page
    # when a notification is tapped.
    def payload_for(notification, unread_count:)
      {
        aps: {
          alert: { title: "Syrus", body: notification.body.to_s.truncate(240) },
          badge: unread_count,
          sound: "default",
          "thread-id" => notification.job_id ? "job-#{notification.job_id}" : "notifications"
        },
        syrus: {
          notification_id: notification.id,
          kind: notification.kind,
          job_id: notification.job_id,
          path: notification.target_path.presence || (notification.job_id ? "/jobs/#{notification.job_id}" : "/notifications")
        }.compact
      }
    end
  end
end
