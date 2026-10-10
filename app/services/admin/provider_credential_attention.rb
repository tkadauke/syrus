module Admin
  class ProviderCredentialAttention
    STALE_AUTH_ERROR_THRESHOLD = 6.hours
    REASON = "stale_provider_credential"
    EVIDENCE_WINDOW = App::ProviderAvailability::AUTH_ERROR_WINDOW

    def self.preload(users, providers: User.agent_providers, now: Time.current)
      Batch.new(users: users, providers: providers, now: now)
    end

    def self.availability_for_user(user, provider, now: Time.current)
      preload([ user ], providers: [ provider ], now: now).availability_for(user, provider)
    end

    def self.attention_for_user(user, provider, availability: nil, now: Time.current)
      batch = preload([ user ], providers: [ provider ], now: now)
      batch.attention_for(user, provider, availability: availability)
    end

    class Batch
      def initialize(users:, providers:, now:)
        @users = Array(users).compact
        @providers = Array(providers).map(&:to_s)
        @now = now
      end

      def availability_for(user, provider)
        user_id = user.id
        provider = provider.to_s
        return not_configured_status(user, provider) unless configured?(user, provider)

        auth_error = current_negative_evidence(user_id, provider, "auth_error")
        return auth_error_status(user, provider, auth_error) if auth_error

        exhausted = current_negative_evidence(user_id, provider, "exhausted")
        return exhausted_status(user, provider, exhausted) if exhausted

        circuit = circuit_for(provider)
        return open_status(user, provider, circuit) if circuit.open? && !circuit.usage_limit?

        available_status(user, provider)
      end

      def attention_for(user, provider, availability: nil)
        availability ||= availability_for(user, provider)
        observed_at = observed_at_for(availability)
        return nil unless availability&.dig(:state).to_s == "auth_error"
        return nil unless observed_at && observed_at <= now - STALE_AUTH_ERROR_THRESHOLD

        count = blocked_work_count(user.id, provider)
        return nil unless count.positive?

        {
          reason: REASON,
          message: "#{label(provider)} credentials have been failing authentication for blocked work.",
          provider: provider.to_s,
          provider_label: label(provider),
          observed_at: observed_at.iso8601,
          stale_after_seconds: STALE_AUTH_ERROR_THRESHOLD.to_i,
          blocked_work_units_count: count
        }
      end

      def first_attention_for(user)
        providers.filter_map do |provider|
          attention_for(user, provider, availability: availability_for(user, provider))
        end.first
      end

      private

      attr_reader :users, :providers, :now

      def configured?(user, provider)
        user.agent_provider_configured?(provider)
      end

      def available_status(user, provider)
        evidence = evidence_payload(user.id, provider)
        return available_without_evidence_status(user, provider) if evidence.blank?

        {
          provider: provider,
          label: label(provider),
          model: nil,
          state: "available",
          open: false,
          usage_exhausted: false,
          retry_after: nil,
          reason: nil,
          message: "#{label(provider)} is available.",
          usage: nil,
          evidence: evidence
        }.merge(pause_metadata(user, provider))
      end

      def auth_error_status(user, provider, evidence)
        {
          provider: provider,
          label: label(provider),
          model: nil,
          state: "auth_error",
          open: true,
          usage_exhausted: false,
          retry_after: nil,
          reason: "Provider authentication expired.",
          message: "#{label(provider)} credentials need reauthorization. Open agent settings to sign in again.",
          usage: nil,
          evidence: evidence_payload(user.id, provider, primary: evidence.summary)
        }.merge(pause_metadata(user, provider))
      end

      def exhausted_status(user, provider, evidence)
        retry_after = evidence.observed_at + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR
        {
          provider: provider,
          label: label(provider),
          model: evidence.model,
          state: "exhausted",
          open: true,
          usage_exhausted: true,
          retry_after: retry_after.iso8601,
          reason: "Provider usage limit exhausted (#{evidence.source.to_s.humanize(capitalize: false)}).",
          message: "#{label(provider)} usage limit reached. This item uses #{label(provider)} until usage resets.",
          usage: nil,
          evidence: evidence_payload(user.id, provider, primary: evidence.summary)
        }.merge(pause_metadata(user, provider))
      end

      def open_status(user, provider, circuit)
        {
          provider: provider,
          label: label(provider),
          model: circuit.model,
          state: "open",
          open: true,
          usage_exhausted: false,
          retry_after: circuit.retry_after&.iso8601,
          reason: circuit.reason.presence || "Provider appears temporarily unavailable.",
          message: "#{label(provider)} appears temporarily unavailable.",
          usage: nil,
          evidence: evidence_payload(user.id, provider)
        }.merge(pause_metadata(user, provider))
      end

      def not_configured_status(user, provider)
        {
          provider: provider,
          label: label(provider),
          model: nil,
          state: "not_configured",
          open: false,
          usage_exhausted: false,
          retry_after: nil,
          reason: "Provider credentials are not configured.",
          message: "#{label(provider)} credentials are not configured.",
          usage: nil,
          evidence: nil
        }.merge(pause_metadata(user, provider).merge(override_active: false))
      end

      def available_without_evidence_status(user, provider)
        {
          provider: provider,
          label: label(provider),
          model: nil,
          state: "available",
          open: false,
          usage_exhausted: false,
          retry_after: nil,
          reason: nil,
          message: "#{label(provider)} is available.",
          usage: nil,
          evidence: nil
        }.merge(pause_metadata(user, provider))
      end

      def evidence_payload(user_id, provider, primary: nil)
        current = primary || latest_displayable_evidence(user_id, provider)&.summary
        latest_positive = evidence_summary_if_not_older_than(latest_positive_evidence(user_id, provider), current)
        latest_negative = evidence_summary_if_not_older_than(latest_negative_evidence(user_id, provider), current)
        return if current.blank? && latest_positive.blank? && latest_negative.blank?

        {
          current: current,
          latest_positive: latest_positive,
          latest_negative: latest_negative
        }.compact
      end

      def current_negative_evidence(user_id, provider, status)
        latest_negative_evidence(user_id, provider, status: status).presence&.then do |evidence|
          evidence unless suppressed_by_positive_after?(user_id, provider, evidence)
        end
      end

      def latest_displayable_evidence(user_id, provider)
        evidence_for(user_id, provider).detect do |evidence|
          !evidence.repaired_for_circuit? &&
            !(evidence.status == "auth_error" && suppressed_by_positive_after?(user_id, provider, evidence))
        end
      end

      def latest_positive_evidence(user_id, provider)
        evidence_for(user_id, provider).detect(&:positive?)
      end

      def latest_negative_evidence(user_id, provider, status: nil)
        evidence_for(user_id, provider).detect do |evidence|
          evidence.negative? &&
            !evidence.repaired_for_circuit? &&
            (status.blank? || evidence.status == status)
        end
      end

      def evidence_for(user_id, provider)
        evidence_by_scope.fetch([ user_id, provider.to_s ], [])
      end

      def evidence_by_scope
        @evidence_by_scope ||= begin
          user_ids = users.map(&:id)
          if user_ids.blank? || providers.blank?
            {}
          else
            ProviderAvailabilityEvidence
              .where(user_id: user_ids, provider: providers)
              .where("observed_at >= ?", now - EVIDENCE_WINDOW)
              .recent
              .to_a
              .group_by { |evidence| [ evidence.user_id, evidence.provider ] }
          end
        end
      end

      def suppressed_by_positive_after?(user_id, provider, evidence)
        evidence_for(user_id, provider).any? do |candidate|
          candidate.positive? &&
            candidate.observed_at > evidence.observed_at &&
            account_matches?(candidate, evidence.account_id) &&
            model_matches?(candidate, evidence.model)
        end
      end

      def account_matches?(evidence, account_id)
        account_id.blank? || evidence.account_id.blank? || evidence.account_id == account_id.to_s
      end

      def model_matches?(evidence, model)
        model.blank? || evidence.model.blank? || evidence.model == model.to_s
      end

      def evidence_summary_if_not_older_than(evidence, current)
        return unless evidence

        current_time = observed_at_for({ evidence: { current: current } })
        evidence.summary if current_time.blank? || evidence.observed_at >= current_time
      end

      def observed_at_for(availability)
        raw = availability&.dig(:evidence, :current, :observed_at) ||
          availability&.dig("evidence", "current", "observed_at")
        Time.zone.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def blocked_work_count(user_id, provider)
        blocked_work_counts.fetch([ user_id, provider.to_s ], 0)
      end

      def blocked_work_counts
        @blocked_work_counts ||= begin
          user_ids = users.map(&:id)
          if user_ids.blank? || providers.blank?
            {}
          else
            WorkUnit
              .joins(:workflow)
              .where(
                state: "blocked",
                blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON,
                workflows: {
                  user_id: user_ids,
                  agent_provider: providers,
                  state: %w[queued running]
                }
              )
              .group("workflows.user_id", "workflows.agent_provider")
              .count
          end
        end
      end

      def circuit_for(provider)
        circuits.fetch(provider.to_s)
      end

      def circuits
        @circuits ||= providers.index_with do |provider|
          ProviderCircuitBreaker.call(provider, now: now, include_logs: false)
        end
      end

      def pause_metadata(user, provider)
        {
          pause_threshold_percent: user.provider_availability_pause_threshold_for(provider),
          pause_enabled: user.provider_availability_pause_enabled?(provider),
          override_active: user.provider_availability_overridden?(provider, evidence_observed_at: latest_displayable_evidence(user.id, provider)&.observed_at)
        }
      end

      def label(provider)
        labels.fetch(provider.to_s)
      end

      def labels
        @labels ||= providers.index_with { |provider| App::Presentation.agent_provider_label(provider) }
      end
    end
  end
end
