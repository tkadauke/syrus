module MobileDevices
  # Sends a clearly-labelled test push to the *current user's* active mobile
  # devices, synchronously, and reports what APNs said per device. Used by the
  # iOS diagnostics screen so a tester can tell which step of push setup failed
  # (no registration, APNs not configured, rejected token, ...).
  #
  # It deliberately does not create a Notification record: a test must not
  # change the unread badge or show up in the user's notification list. The
  # deep link (`/notifications`) is a real, always-present SPA route so the
  # tester can verify that tapping the push navigates inside the app.
  class TestPush
    TARGET_PATH = "/notifications".freeze

    DeviceResult = Struct.new(:device, :outcome, :status, :reason, keyword_init: true)
    Result = Struct.new(:configured, :results, keyword_init: true) do
      def delivered = results.count { |r| r.outcome == "delivered" }
    end

    def initialize(user:, token: nil, client: MobileDevices::PushDelivery.client)
      @user = user
      @token = token.to_s.downcase.presence
      @client = client
    end

    def call
      return Result.new(configured: false, results: []) unless @client.configured?

      Result.new(configured: true, results: devices.map { |device| deliver(device) })
    end

    def devices
      scope = @user.mobile_devices.active
      scope = scope.where(token: @token) if @token
      scope.order(:id)
    end

    private

    def deliver(device)
      result = @client.deliver(device: device, payload: payload, collapse_id: "test-#{device.id}")
      if result.success?
        device.update_columns(last_delivered_at: Time.current)
        DeviceResult.new(device: device, outcome: "delivered", status: result.status)
      elsif result.invalid_token?
        device.disable!(result.reason || "http_#{result.status}")
        DeviceResult.new(device: device, outcome: "token_rejected", status: result.status, reason: result.reason)
      else
        DeviceResult.new(device: device, outcome: "failed", status: result.status, reason: result.reason)
      end
    rescue StandardError => e
      Rails.logger.warn("[apns] test push to mobile_device=#{device.id} errored: #{e.class}: #{e.message}")
      DeviceResult.new(device: device, outcome: "error", reason: e.class.name)
    end

    def payload
      {
        aps: {
          alert: { title: PushDelivery::TITLE, body: I18n.t("mobile_devices.test_push.body", locale: @user.try(:locale) || I18n.locale) },
          sound: "default",
          "thread-id": "syrus-test"
        },
        syrus: { kind: "test", target_path: TARGET_PATH }
      }
    end
  end
end
