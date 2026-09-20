module ProviderRouting
  class AvailabilitySelector
    Decision = Data.define(:candidate, :original_candidate, :reason, :availability, :candidate_availability, :decided_at, :exhausted) do
      def selected_provider = candidate&.provider
      def failover? = selected_provider.present? && original_candidate&.provider.present? && selected_provider != original_candidate.provider
      def exhausted? = exhausted

      def artifact
        {
          "original_provider" => original_candidate&.provider,
          "original_model" => original_candidate&.model,
          "original_effort_level" => original_candidate&.effort_level,
          "selected_provider" => candidate&.provider,
          "selected_model" => candidate&.model,
          "selected_effort_level" => candidate&.effort_level,
          "reason" => reason,
          "availability_state" => availability_state(availability),
          "candidate_availability_state" => availability_state(candidate_availability),
          "evidence_observed_at" => evidence_observed_at(availability)&.iso8601,
          "candidate_evidence_observed_at" => evidence_observed_at(candidate_availability)&.iso8601,
          "decided_at" => decided_at.iso8601,
          "automatic_failover" => true,
          "manual_override" => false,
          "exhausted" => exhausted?,
          "unavailable" => unavailable_summary(availability)
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

      def unavailable_summary(payload)
        return nil unless payload

        evidence = payload.dig(:evidence, :current) || payload.dig("evidence", "current") || payload.dig(:usage, :evidence) || payload.dig("usage", "evidence") || {}
        usage = payload[:usage] || payload["usage"] || {}
        {
          "provider" => payload[:provider] || payload["provider"] || original_candidate&.provider,
          "label" => payload[:label] || payload["label"],
          "state" => payload[:state] || payload["state"],
          "reason" => payload[:reason] || payload["reason"],
          "retry_after" => payload[:retry_after] || payload["retry_after"],
          "reset_at" => reset_at(usage),
          "observed_at" => evidence_observed_at(payload)&.iso8601,
          "evidence" => {
            "status" => evidence[:status] || evidence["status"],
            "source" => evidence[:source] || evidence["source"],
            "observed_at" => evidence[:observed_at] || evidence["observed_at"]
          }.compact
        }.compact
      end

      def reset_at(usage)
        ProviderRouting::UsageWindows.earliest_reset_at(usage)
      end
    end

    def self.call(job:, task_key:, original_candidate: nil, reason: nil, availability: nil, now: Time.current)
      new(
        job: job,
        task_key: task_key,
        original_candidate: original_candidate,
        reason: reason,
        availability: availability,
        now: now
      ).call
    end

    def self.candidate(provider:, model: nil, effort_level: nil)
      ProviderRouting::Resolver::Candidate.new(provider: provider, model: model, effort_level: effort_level)
    end

    def initialize(job:, task_key:, original_candidate: nil, reason: nil, availability: nil, now: Time.current)
      @job = job
      @task_key = task_key
      @original_candidate = original_candidate
      @reason = reason
      @availability = availability
      @now = now
    end

    def call
      candidates.each do |candidate|
        refresh_stale_usage(candidate.provider)
        candidate_availability = App::ProviderAvailability.for_user(user, candidate.provider, now: now)
        next unless available_enough?(candidate.provider, candidate_availability)

        return decision(candidate, candidate_availability: candidate_availability, exhausted: false)
      end

      decision(candidates.first, candidate_availability: nil, exhausted: true)
    end

    private

    attr_reader :job, :task_key, :original_candidate, :reason, :availability, :now

    def candidates
      @candidates ||= ProviderRouting::Resolver.call(job: job, task_key: task_key).presence ||
        ProviderRouting::Resolver::HARDCODED_FALLBACK
    end

    def user = job.owner_user || job.user

    def decision(candidate, candidate_availability:, exhausted:)
      Decision.new(
        candidate: candidate,
        original_candidate: original_candidate || candidate,
        reason: reason,
        availability: availability,
        candidate_availability: candidate_availability,
        decided_at: now,
        exhausted: exhausted
      )
    end

    # Basic availability (actively erroring/rate-limited/exhausted/paused)
    # always applies, regardless of whether the user has opted into
    # proactive threshold-based pausing for any candidate provider or
    # configured a ProviderRoutingRule — a candidate that is provably
    # unavailable right now should never be selected. The opt-in
    # `provider_availability_pause_enabled?` setting is reserved for the
    # more aggressive proactive check below (pausing *before* a provider
    # is actually broken, once its remaining usage drops under a
    # configured threshold).
    def available_enough?(provider, payload)
      return false if actively_unavailable?(provider, payload)

      remaining = remaining_percent(payload)
      remaining.nil? || !user.provider_availability_pause_enabled?(provider) || remaining >= user.provider_availability_pause_threshold_for(provider)
    end

    def actively_unavailable?(provider, payload)
      return true if user.provider_availability_overridden?(provider, evidence_observed_at: evidence_observed_at(payload))
      return true if payload&.dig(:open) == true || payload&.dig("open") == true
      return true if payload&.dig(:usage_exhausted) == true || payload&.dig("usage_exhausted") == true
      return true if payload&.dig(:state).to_s.in?(%w[open rate_limited exhausted auth_error])
      return true if payload&.dig("state").to_s.in?(%w[open rate_limited exhausted auth_error])

      false
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
end
