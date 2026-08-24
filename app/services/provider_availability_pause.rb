class ProviderAvailabilityPause
  RECHECK_INTERVAL = 10.minutes

  Decision = Data.define(:pause, :reason, :provider, :threshold_percent, :remaining_percent, :retry_at, :availability) do
    def pause? = pause

    def details
      usage = availability&.dig(:usage) || {}
      {
        "action" => "delay_until",
        "reason" => reason,
        "provider" => provider,
        "threshold_percent" => threshold_percent,
        "remaining_percent" => remaining_percent,
        "retry_at" => retry_at&.iso8601,
        "message" => availability&.dig(:message),
        "usage_status" => usage[:status] || usage["status"],
        "observed_at" => usage[:observed_at] || usage["observed_at"],
        "reset_at" => reset_at
      }.compact
    end

    def reset_at
      usage = availability&.dig(:usage) || {}
      windows = usage[:windows] || usage["windows"] || {}
      [ windows.dig(:five_hour, :reset_at), windows.dig("five_hour", "reset_at"),
        windows.dig(:weekly, :reset_at), windows.dig("weekly", "reset_at") ].compact.min
    end
  end

  def self.call(workflow:, now: Time.current)
    new(workflow: workflow, now: now).call
  end

  def initialize(workflow:, now: Time.current)
    @workflow = workflow
    @now = now
  end

  def call
    return admit unless provider.present?
    return admit unless user.provider_availability_pause_enabled?(provider)

    refresh_stale_usage
    availability = App::ProviderAvailability.for_user(user, provider, now: now)
    return admit if overridden?(availability)
    return pause("provider_usage_exhausted", availability) if usage_exhausted?(availability)
    return pause("provider_usage_low", availability) if low_usage?(availability)

    admit
  end

  private

  attr_reader :workflow, :now

  def user = workflow.user
  def provider = workflow.agent_provider.presence || workflow.job.workflow_agent_provider

  def admit
    Decision.new(
      pause: false,
      reason: nil,
      provider: provider,
      threshold_percent: threshold,
      remaining_percent: nil,
      retry_at: nil,
      availability: nil
    )
  end

  def pause(reason, availability)
    Decision.new(
      pause: true,
      reason: reason,
      provider: provider,
      threshold_percent: threshold,
      remaining_percent: remaining_percent(availability),
      retry_at: retry_at(availability),
      availability: availability
    )
  end

  def threshold
    user.provider_availability_pause_threshold_for(provider)
  end

  def refresh_stale_usage
    AgentProviders.for(provider).refresh_stale_usage!(user: user, now: now)
  rescue AgentProviders::ConfigurationError
    nil
  end

  def usage_exhausted?(availability)
    availability&.dig(:usage_exhausted) == true || availability&.dig(:state).to_s == "exhausted"
  end

  def low_usage?(availability)
    remaining = remaining_percent(availability)
    remaining.present? && remaining < threshold
  end

  def remaining_percent(availability)
    value = availability&.dig(:usage, :remaining_percent) || availability&.dig("usage", "remaining_percent")
    return if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def retry_at(availability)
    reset = parse_time(
      availability&.dig(:retry_after) ||
        availability&.dig("retry_after") ||
        earliest_reset_at(availability)
    )
    return reset if reset&.future?

    now + RECHECK_INTERVAL
  end

  def earliest_reset_at(availability)
    usage = availability&.dig(:usage) || availability&.dig("usage") || {}
    windows = usage[:windows] || usage["windows"] || {}
    [ windows.dig(:five_hour, :reset_at), windows.dig("five_hour", "reset_at"),
      windows.dig(:weekly, :reset_at), windows.dig("weekly", "reset_at") ].compact.min
  end

  def overridden?(availability)
    user.provider_availability_overridden?(provider, evidence_observed_at: evidence_observed_at(availability))
  end

  def evidence_observed_at(availability)
    parse_time(
      availability&.dig(:evidence, :current, :observed_at) ||
        availability&.dig("evidence", "current", "observed_at") ||
        availability&.dig(:usage, :observed_at) ||
        availability&.dig("usage", "observed_at")
    )
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
