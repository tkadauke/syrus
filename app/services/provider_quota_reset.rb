class ProviderQuotaReset
  RETRY_BUFFER = 5.minutes
  RESET_AT_PATTERN = /
    \bresets?
    (?:\s+at)?
    \s+
    (?<hour>\d{1,2})
    (?::(?<minute>\d{2}))?
    \s*
    (?<meridian>am|pm)
    \b
    (?:\s*\((?<timezone>[^)]+)\))?
  /ix

  RELATIVE_RESET_PATTERN = /
    \bresets?
    \s+
    in
    \s+
    (?<amount>\d+)
    \s*
    (?<unit>seconds?|minutes?|hours?)
    \b
  /ix

  def self.retry_after_for_run(run, now: Time.current) = new(run, now: now).retry_after

  def initialize(run, now: Time.current)
    @run = run
    @now = now
  end

  def retry_after
    structured_codex_reset || textual_reset
  end

  private

  attr_reader :run, :now

  def structured_codex_reset
    return unless run&.agent_provider.to_s == "codex"

    reset_at = codex_reset_times.min
    reset_at ? reset_at + RETRY_BUFFER : nil
  end

  def codex_reset_times
    user = run&.user
    snapshot = user&.codex_usage_snapshot || {}
    observed_at = user&.codex_usage_observed_at
    spend_window = snapshot.dig("spend_control", "individual_limit")
    windows = [
      snapshot["primary"],
      snapshot["secondary"],
      spend_window,
      *Array(snapshot["additional_rate_limits"]).flat_map { |entry| [ entry["primary"], entry["secondary"] ] }
    ].compact

    return [ reset_time_for_window(spend_window, observed_at:) ].compact if snapshot.dig("spend_control", "reached") == true

    exhausted = windows.select { |window| exhausted_window?(window) }.filter_map { |window| reset_time_for_window(window, observed_at:) }
    return exhausted if exhausted.present?
    return [] unless snapshot["rate_limit_reached_type"].present?

    windows.filter_map { |window| reset_time_for_window(window, observed_at:) }
  end

  def reset_time_for_window(window, observed_at:)
    return unless window.is_a?(Hash)

    time_from_value(window["reset_at"]) ||
      reset_after_seconds(window["reset_after_seconds"], observed_at: observed_at)
  end

  def exhausted_window?(window)
    remaining = numeric(window["remaining_percent"])
    used = numeric(window["used_percent"])
    remaining.present? ? remaining <= 0.0 : used.present? && used >= 100.0
  end

  def textual_reset
    text = diagnostic_text
    absolute_reset(text) || relative_reset(text)
  end

  def absolute_reset(text)
    match = text.match(RESET_AT_PATTERN)
    return unless match

    zone = Time.find_zone(match[:timezone].presence) || Time.zone
    local_anchor = anchor_time.in_time_zone(zone)
    hour = match[:hour].to_i
    minute = match[:minute].presence&.to_i || 0
    meridian = match[:meridian].downcase
    hour = 0 if hour == 12
    hour += 12 if meridian == "pm"

    reset_at = zone.local(local_anchor.year, local_anchor.month, local_anchor.day, hour, minute)
    reset_at += 1.day unless reset_at > local_anchor
    reset_at + RETRY_BUFFER
  end

  def relative_reset(text)
    match = text.match(RELATIVE_RESET_PATTERN)
    return unless match

    amount = match[:amount].to_i
    duration = case match[:unit].downcase
    when /\Aseconds?/ then amount.seconds
    when /\Aminutes?/ then amount.minutes
    when /\Ahours?/ then amount.hours
    end
    duration ? anchor_time + duration + RETRY_BUFFER : nil
  end

  def anchor_time
    run&.finished_at || run&.updated_at || now
  end

  def diagnostic_text
    [
      run&.agent_outcome,
      run&.run_failure_classification&.classification,
      run&.run_diagnostic&.error_class,
      run&.run_diagnostic&.error_message,
      recent_log_text
    ].compact.join(" ")
  end

  def recent_log_text
    return unless run

    run.job_logs.reorder(sequence: :desc).limit(10).pluck(:chunk).join(" ")
  end

  def time_from_value(value)
    return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)
    return Time.zone.at(value) if value.is_a?(Numeric)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def reset_after_seconds(value, observed_at:)
    return if value.blank? || observed_at.blank?

    observed_at + value.to_f.seconds
  end

  def numeric(value)
    Float(value)
  rescue ArgumentError, TypeError
    nil
  end
end
