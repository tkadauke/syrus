module ProviderRouting
  class AvailabilitySelector
    Decision = Data.define(:candidate, :original_candidate, :reason, :availability, :candidate_availability, :decided_at, :exhausted, :routing_resolution) do
      def selected_provider = candidate&.provider
      def failover? = selected_provider.present? && original_candidate&.provider.present? && selected_provider != original_candidate.provider
      def exhausted? = exhausted
      def held? = routing_resolution&.held? || false

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
          "held" => held?,
          "routing_resolution" => routing_resolution&.explanation,
          "unavailable" => unavailable_summary(unavailable_payload)
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
          "reset_at" => reset_at(usage)&.iso8601,
          "observed_at" => evidence_observed_at(payload)&.iso8601,
          "evidence" => {
            "status" => evidence[:status] || evidence["status"],
            "source" => evidence[:source] || evidence["source"],
            "observed_at" => evidence[:observed_at] || evidence["observed_at"]
          }.compact
        }.compact
      end

      def unavailable_payload
        availability || (candidate_availability if exhausted?)
      end

      def reset_at(usage)
        ProviderRouting::UsageWindows.earliest_reset_at(usage)
      end
    end

    def self.call(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, original_candidate: nil, reason: nil, availability: nil, now: Time.current, released_hold_rule_ids: [])
      new(
        job: job,
        task_key: task_key,
        trigger: trigger,
        workflow_trigger_kind: workflow_trigger_kind,
        original_candidate: original_candidate,
        reason: reason,
        availability: availability,
        now: now,
        released_hold_rule_ids: released_hold_rule_ids
      ).call
    end

    def self.candidate(provider:, model: nil, effort_level: nil)
      ProviderRouting::Resolver::Candidate.new(provider: provider, model: model, effort_level: effort_level)
    end

    def initialize(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, original_candidate: nil, reason: nil, availability: nil, now: Time.current, released_hold_rule_ids: [])
      @job = job
      @task_key = task_key
      @trigger = trigger
      @workflow_trigger_kind = workflow_trigger_kind
      @original_candidate = original_candidate
      @reason = reason
      @availability = availability
      @now = now
      @released_hold_rule_ids = released_hold_rule_ids
    end

    def call
      return decision(nil, candidate_availability: nil, exhausted: false) if routing_resolution.held?

      first_unavailable_candidate = nil
      first_unavailable_availability = nil

      candidates.each do |candidate|
        if (credential_availability = credential_unavailability(candidate.provider))
          first_unavailable_candidate ||= candidate
          first_unavailable_availability ||= credential_availability
          next
        end

        refresh_stale_usage(candidate.provider)
        candidate_availability = App::ProviderAvailability.for_user(user, candidate.provider, now: now)
        unless available_enough?(candidate.provider, candidate_availability)
          first_unavailable_candidate ||= candidate
          first_unavailable_availability ||= candidate_availability
          next
        end

        return decision(candidate, candidate_availability: candidate_availability, exhausted: false)
      end

      decision(
        first_unavailable_candidate || candidates.first,
        candidate_availability: first_unavailable_availability,
        exhausted: true
      )
    end

    private

    attr_reader :job, :task_key, :trigger, :workflow_trigger_kind, :original_candidate, :reason, :availability, :now, :released_hold_rule_ids

    def candidates
      @candidates ||= if routing_resolution.held?
        []
      else
        routing_resolution.candidates.presence || ProviderRouting::Resolver::HARDCODED_FALLBACK
      end
    end

    def routing_resolution
      @routing_resolution ||= ProviderRouting::Resolver.resolve(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind, released_hold_rule_ids: released_hold_rule_ids)
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
        exhausted: exhausted,
        routing_resolution: routing_resolution
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

    UNAVAILABLE_STATES = %w[open rate_limited exhausted auth_error model_unsupported].freeze

    def actively_unavailable?(provider, payload)
      return true if user.provider_availability_overridden?(provider, evidence_observed_at: evidence_observed_at(payload))
      return true if payload&.dig(:open) == true || payload&.dig("open") == true
      return true if payload&.dig(:usage_exhausted) == true || payload&.dig("usage_exhausted") == true
      # model_unsupported belongs here with auth_error: both mean this
      # provider will refuse every request until it is reconfigured, so the
      # next candidate is strictly better than retrying this one.
      return true if payload&.dig(:state).to_s.in?(UNAVAILABLE_STATES)
      return true if payload&.dig("state").to_s.in?(UNAVAILABLE_STATES)

      false
    end

    def credential_unavailability(provider)
      provider_class = AgentProviders.for(provider)
      return nil if provider_class.configured_for_user?(user)

      {
        provider: provider,
        state: "auth_error",
        reason: "provider_credentials_missing",
        message: "#{provider_class.display_name} credentials are not configured."
      }
    rescue AgentProviders::ConfigurationError
      {
        provider: provider,
        state: "auth_error",
        reason: "unknown_provider",
        message: "Unknown agent provider: #{provider.inspect}."
      }
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
