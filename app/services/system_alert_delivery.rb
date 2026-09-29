require "net/http"

class SystemAlertDelivery
  MissingPayload = Class.new(StandardError)
  MAX_DELIVERY_ATTEMPTS = 3
  RETRY_DELAYS = [ 1.minute, 5.minutes ].freeze
  WEBHOOK_TIMEOUT = 5

  def self.deliver(alerts)
    new(alerts).deliver
  end

  def self.configured?
    ENV["SYRUS_ALERT_WEBHOOK_URL"].to_s.strip.present? ||
      ENV["SYRUS_ALERT_EMAIL_TO"].to_s.split(",").map(&:strip).reject(&:blank?).any?
  end

  def initialize(alerts)
    @alerts = Array(alerts)
  end

  def deliver
    return unless configured?

    deliver_current_alerts
    deliver_due_notifications
  end

  private

  attr_reader :alerts

  def deliver_current_alerts
    alarm_alerts.each do |alert|
      notification = claim(alert)
      next unless notification

      payload = payload_for(alert)
      notification.update!(payload: payload, alert_id: alert.id, severity: alert.severity.to_s, title: text(alert.title))
      deliver_notification(notification, payload, log_key: alert.dismissal_key)
    end
  end

  def deliver_due_notifications
    SystemAlertNotification.retry_due.find_each do |notification|
      deliver_notification(notification, notification.payload, log_key: notification.dismissal_key)
    end
  end

  def deliver_notification(notification, payload, log_key:)
    raise MissingPayload, "alert notification has no retry payload" if payload.blank?

    payload = payload.deep_symbolize_keys
    deliver_to_sinks(payload)
    notification.update!(
      delivered_at: Time.current,
      delivery_error_class: nil,
      delivery_error_message: nil,
      next_attempt_at: nil,
      dead_lettered_at: nil
    )
  rescue StandardError => e
    record_failure(notification, e)
    Rails.logger.warn("[SystemAlertDelivery] failed to deliver #{log_key}: #{e.class}: #{e.message}")
  end

  def configured?
    self.class.configured?
  end

  def alarm_alerts
    alerts.select { |alert| alert.severity.to_sym == :alarm && alert.dismissal_key.present? }
  end

  def claim(alert)
    SystemAlertNotification.create!(
      dismissal_key: alert.dismissal_key,
      alert_id: alert.id,
      severity: alert.severity.to_s,
      title: alert.title
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise unless duplicate_claim?(e)

    existing_claim(alert)
  end

  def duplicate_claim?(error)
    error.is_a?(ActiveRecord::RecordNotUnique) ||
      error.record&.errors&.of_kind?(:dismissal_key, :taken)
  end

  def existing_claim(alert)
    notification = SystemAlertNotification.find_by(dismissal_key: alert.dismissal_key)
    return unless notification&.retry_due?

    notification
  end

  def record_failure(notification, error)
    attempts = notification.delivery_attempts + 1
    dead_lettered_at = attempts >= MAX_DELIVERY_ATTEMPTS ? Time.current : nil

    notification.update_columns(
      delivery_attempts: attempts,
      delivery_error_class: error.class.name,
      delivery_error_message: error.message.to_s.truncate(1_000),
      next_attempt_at: dead_lettered_at ? nil : next_attempt_at(attempts),
      dead_lettered_at: dead_lettered_at,
      updated_at: Time.current
    )
  end

  def next_attempt_at(attempts)
    Time.current + RETRY_DELAYS.fetch(attempts - 1, RETRY_DELAYS.last)
  end

  def payload_for(alert)
    {
      id: alert.id,
      dismissal_key: alert.dismissal_key,
      severity: alert.severity.to_s,
      title: text(alert.title),
      message: text(alert.message),
      action_steps: Array(alert.action_steps).map { |step| text(step) },
      cta: cta_payload(alert.cta),
      app_url: app_url
    }.compact
  end

  def cta_payload(cta)
    return nil if cta.blank?

    {
      text: text(cta[:text] || cta["text"]),
      url: absolute_url(cta[:path] || cta["path"])
    }.compact
  end

  def text(value)
    CGI.unescapeHTML(ActionView::Base.full_sanitizer.sanitize(value.to_s)).squish
  end

  def absolute_url(path)
    return if path.blank?
    return path if path.to_s.match?(%r{\Ahttps?://}i)

    "#{app_url}#{path.to_s.start_with?("/") ? path : "/#{path}"}"
  end

  def app_url
    scheme = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SYRUS_ASSUME_SSL", "true")) ? "https" : "http"
    "#{scheme}://#{ENV.fetch("SYRUS_APP_HOST", "localhost")}".delete_suffix("/")
  end

  def deliver_to_sinks(payload)
    deliver_webhook(payload) if webhook_url.present?
    SystemAlertMailer.alarm(payload, to: email_to).deliver_now if email_to.any?
  end

  def deliver_webhook(payload)
    uri = URI.parse(webhook_url)
    request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
    request.body = JSON.generate(payload)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: WEBHOOK_TIMEOUT, read_timeout: WEBHOOK_TIMEOUT) do |http|
      http.request(request)
    end
    raise "alert webhook returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end

  def webhook_url
    ENV["SYRUS_ALERT_WEBHOOK_URL"].to_s.strip.presence
  end

  def email_to
    ENV["SYRUS_ALERT_EMAIL_TO"].to_s.split(",").map(&:strip).reject(&:blank?)
  end
end
