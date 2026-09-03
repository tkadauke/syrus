class ProviderFailoverSelector
  FAILOVER_CAUSES = {
    "provider_usage_exhausted" => "usage_exhausted",
    "provider_usage_low" => "usage_low",
    "provider_rate_limited" => "rate_limited",
    "provider_auth_error" => "auth_error"
  }.freeze

  Decision = Data.define(:selected_provider, :original_provider, :reason, :availability, :candidate_availability, :decided_at, :manual_override) do
    def failover? = selected_provider.present? && selected_provider != original_provider

    def artifact
      {
        "original_provider" => original_provider,
        "selected_provider" => selected_provider,
        "reason" => reason,
        "availability_state" => availability_state(availability),
        "candidate_availability_state" => availability_state(candidate_availability),
        "evidence_observed_at" => evidence_observed_at(availability)&.iso8601,
        "candidate_evidence_observed_at" => evidence_observed_at(candidate_availability)&.iso8601,
        "decided_at" => decided_at.iso8601,
        "automatic_failover" => true,
        "manual_override" => manual_override
      }.compact
    end

    private

    def availability_state(payload)
      payload&.dig(:state) || payload&.dig("state") || "available"
    end

    def evidence_observed_at(payload)
      value =
        payload&.dig(:evidence, :current, :observed_at) ||
        payload&.dig("evidence", "current", "observed_at") ||
        payload&.dig(:usage, :observed_at) ||
        payload&.dig("usage", "observed_at")
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end

  def self.call(workflow:, reason:, availability:, now: Time.current)
    new(workflow: workflow, reason: reason, availability: availability, now: now).call
  end

  def initialize(workflow:, reason:, availability:, now: Time.current)
    @workflow = workflow
    @reason = reason
    @availability = availability
    @now = now
  end

  def call
    return no_failover unless unstarted_workflow?

    candidates.each do |candidate|
      refresh_stale_usage(candidate)
      candidate_availability = App::ProviderAvailability.for_user(user, candidate, now: now)
      next unless available_enough?(candidate, candidate_availability)

      return Decision.new(
        selected_provider: candidate,
        original_provider: original_provider,
        reason: reason,
        availability: availability,
        candidate_availability: candidate_availability,
        decided_at: now,
        manual_override: false
      )
    end

    no_failover
  end

  private

  attr_reader :workflow, :reason, :availability, :now

  def user = workflow.user
  def job = workflow.job
  def original_provider = workflow.agent_provider.presence || job.workflow_agent_provider

  def no_failover
    Decision.new(
      selected_provider: nil,
      original_provider: original_provider,
      reason: reason,
      availability: availability,
      candidate_availability: nil,
      decided_at: now,
      manual_override: false
    )
  end

  def unstarted_workflow?
    workflow.runs.none?
  end

  def candidates
    job.agent_provider_failover_candidates(cause: failover_cause)
  end

  def failover_cause
    FAILOVER_CAUSES.fetch(reason.to_s, "provider_transient")
  end

  def available_enough?(provider, payload)
    return false if user.provider_availability_overridden?(provider, evidence_observed_at: evidence_observed_at(payload))
    return false if payload&.dig(:open) == true || payload&.dig("open") == true
    return false if payload&.dig(:usage_exhausted) == true || payload&.dig("usage_exhausted") == true
    return false if payload&.dig(:state).to_s.in?(%w[open rate_limited exhausted auth_error])
    return false if payload&.dig("state").to_s.in?(%w[open rate_limited exhausted auth_error])

    remaining = remaining_percent(payload)
    remaining.nil? || !user.provider_availability_pause_enabled?(provider) || remaining >= user.provider_availability_pause_threshold_for(provider)
  end

  def refresh_stale_usage(provider)
    AgentProviders.for(provider).refresh_stale_usage!(user: user, now: now)
  rescue AgentProviders::ConfigurationError
    nil
  end

  def remaining_percent(payload)
    value = payload&.dig(:usage, :remaining_percent) || payload&.dig("usage", "remaining_percent")
    return if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def evidence_observed_at(payload)
    value =
      payload&.dig(:evidence, :current, :observed_at) ||
      payload&.dig("evidence", "current", "observed_at") ||
      payload&.dig(:usage, :observed_at) ||
      payload&.dig("usage", "observed_at")
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
