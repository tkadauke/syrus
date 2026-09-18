module ProviderRouting
  # The "is this candidate provider usable right now" predicate, extracted
  # from ProviderFailoverSelector#available_enough? so Resolver-driven
  # candidate selection (Workflows::Base#instantiate, StepDispatcher) and
  # the still-active ProviderFailoverSelector share one definition instead
  # of drifting. ProviderFailoverSelector is retired in a later Job of this
  # Epic; this module is meant to outlive it.
  #
  # `availability` is the payload shape returned by
  # App::ProviderAvailability.for_user, which already folds in
  # ProviderCircuitBreaker state (see App::ProviderAvailability#compute_status).
  module AvailabilityCheck
    def self.available_enough?(user:, provider:, availability:)
      return false if user.provider_availability_overridden?(provider, evidence_observed_at: evidence_observed_at(availability))
      return false if availability&.dig(:open) == true || availability&.dig("open") == true
      return false if availability&.dig(:usage_exhausted) == true || availability&.dig("usage_exhausted") == true
      return false if availability&.dig(:state).to_s.in?(%w[open rate_limited exhausted auth_error])
      return false if availability&.dig("state").to_s.in?(%w[open rate_limited exhausted auth_error])

      remaining = remaining_percent(availability)
      remaining.nil? || !user.provider_availability_pause_enabled?(provider) || remaining >= user.provider_availability_pause_threshold_for(provider)
    end

    def self.remaining_percent(availability)
      value = availability&.dig(:usage, :remaining_percent) || availability&.dig("usage", "remaining_percent")
      return if value.blank?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def self.evidence_observed_at(availability)
      value =
        availability&.dig(:evidence, :current, :observed_at) ||
        availability&.dig("evidence", "current", "observed_at") ||
        availability&.dig(:usage, :observed_at) ||
        availability&.dig("usage", "observed_at")
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
