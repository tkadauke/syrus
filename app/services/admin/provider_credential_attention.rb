module Admin
  class ProviderCredentialAttention
    STALE_AUTH_ERROR_THRESHOLD = 6.hours
    REASON = "stale_provider_credential"

    def self.availability_for_user(user, provider, now: Time.current)
      new(user: user, provider: provider, now: now).availability
    end

    def self.attention_for_user(user, provider, availability: nil, now: Time.current)
      new(user: user, provider: provider, availability: availability, now: now).attention
    end

    def initialize(user:, provider:, availability: nil, now: Time.current)
      @user = user
      @provider = provider.to_s
      @availability = availability
      @now = now
    end

    def availability
      return not_configured_status unless configured?

      @availability ||= App::ProviderAvailability.for_user(user, provider, now: now)
      @availability || available_without_evidence_status
    end

    def attention
      return nil unless stale_auth_error?
      return nil unless blocked_work_count.positive?

      {
        reason: REASON,
        message: "#{label} credentials have been failing authentication for blocked work.",
        provider: provider,
        provider_label: label,
        observed_at: auth_error_observed_at&.iso8601,
        stale_after_seconds: STALE_AUTH_ERROR_THRESHOLD.to_i,
        blocked_work_units_count: blocked_work_count
      }
    end

    private

    attr_reader :user, :provider, :now

    def configured?
      user.agent_provider_configured?(provider)
    end

    def stale_auth_error?
      availability&.dig(:state).to_s == "auth_error" &&
        auth_error_observed_at.present? &&
        auth_error_observed_at <= now - STALE_AUTH_ERROR_THRESHOLD
    end

    def auth_error_observed_at
      @auth_error_observed_at ||= begin
        raw = availability&.dig(:evidence, :current, :observed_at) ||
          availability&.dig("evidence", "current", "observed_at")
        Time.zone.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end

    def blocked_work_count
      @blocked_work_count ||= WorkUnit
        .joins(:workflow)
        .where(
          state: "blocked",
          blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON,
          workflows: {
            user_id: user.id,
            agent_provider: provider,
            state: %w[queued running]
          }
        )
        .count
    end

    def not_configured_status
      {
        provider: provider,
        label: label,
        model: nil,
        state: "not_configured",
        open: false,
        usage_exhausted: false,
        retry_after: nil,
        reason: "Provider credentials are not configured.",
        message: "#{label} credentials are not configured.",
        usage: nil,
        evidence: nil,
        pause_threshold_percent: user.provider_availability_pause_threshold_for(provider),
        pause_enabled: user.provider_availability_pause_enabled?(provider),
        override_active: false
      }
    end

    def available_without_evidence_status
      {
        provider: provider,
        label: label,
        model: nil,
        state: "available",
        open: false,
        usage_exhausted: false,
        retry_after: nil,
        reason: nil,
        message: "#{label} is available.",
        usage: nil,
        evidence: nil,
        pause_threshold_percent: user.provider_availability_pause_threshold_for(provider),
        pause_enabled: user.provider_availability_pause_enabled?(provider),
        override_active: false
      }
    end

    def label
      @label ||= App::Presentation.agent_provider_label(provider)
    end
  end
end
