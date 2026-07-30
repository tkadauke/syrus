class ClaudeUsageProbe
  WARNING_REMAINING_PERCENT = 20.0

  Result = Data.define(:status, :snapshot, :message) do
    def ok?
      %w[ok warning exhausted unsupported].include?(status.to_s)
    end
  end

  def self.record_status_line_payload(user:, payload:)
    new(user: user).record_status_line_payload(payload)
  end

  def initialize(user:)
    @user = user
  end

  def record_status_line_payload(payload)
    rate_limits = payload["rate_limits"]
    return unsupported("Claude status-line payload did not include rate limits.") unless rate_limits.is_a?(Hash)

    snapshot = normalize_snapshot(rate_limits)
    persist(status: classify(snapshot), snapshot: snapshot, message: message_for(snapshot))
  rescue StandardError => e
    Rails.logger.warn("Claude usage probe failed for user #{@user.id}: #{e.class}: #{e.message}")
    persist(status: "error", snapshot: {}, message: e.message)
  end

  private

  def unsupported(message)
    Result.new(status: "unsupported", snapshot: {}, message: message)
  end

  def normalize_snapshot(rate_limits)
    five_hour = normalize_window(rate_limits["five_hour"], label: "5h")
    seven_day = normalize_window(rate_limits["seven_day"], label: "weekly")
    {
      "source" => "claude_status_line",
      "five_hour" => five_hour,
      "seven_day" => seven_day,
      "remaining_percent" => remaining_percent(five_hour, seven_day)
    }.compact
  end

  def normalize_window(window, label:)
    return unless window.is_a?(Hash)

    used = numeric(window["used_percentage"] || window["used_percent"])
    {
      "label" => label,
      "used_percent" => used,
      "remaining_percent" => used.nil? ? nil : [ 100.0 - used, 0.0 ].max,
      "reset_at" => window["resets_at"] || window["reset_at"]
    }.compact
  end

  def classify(snapshot)
    remaining = snapshot["remaining_percent"]
    return "exhausted" if remaining.present? && remaining <= 0.0
    return "warning" if remaining.present? && remaining <= WARNING_REMAINING_PERCENT

    "ok"
  end

  def message_for(snapshot)
    remaining = snapshot["remaining_percent"]
    return "Claude usage limit has been reached." if classify(snapshot) == "exhausted"
    return "Claude usage has #{remaining.round}% remaining (#{limit_breakdown(snapshot)})." if remaining.present?

    "Claude usage snapshot refreshed."
  end

  def persist(status:, snapshot:, message:)
    @user.update!(
      claude_usage_status: status,
      claude_usage_observed_at: Time.current,
      claude_usage_snapshot: snapshot
    )
    Result.new(status: status, snapshot: snapshot, message: message)
  end

  def remaining_percent(*windows)
    windows.filter_map { |window| window&.dig("remaining_percent") }.min
  end

  def limit_breakdown(snapshot)
    [ snapshot["five_hour"], snapshot["seven_day"] ].compact.filter_map do |window|
      remaining = window["remaining_percent"]
      next if remaining.blank?

      "#{window.fetch("label")} #{remaining.round}%"
    end.join(", ")
  end

  def numeric(value)
    return if value.nil?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end
end
