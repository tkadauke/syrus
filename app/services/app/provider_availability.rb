module App
  class ProviderAvailability
    def self.for_user(user, provider, now: Time.current)
      new(user: user, provider: provider, now: now).status
    end

    def self.broadcast_changed(user:, provider:, now: Time.current)
      return unless user && provider.present?

      AppEvents.broadcast(
        user: user,
        type: "provider_availability.changed",
        resource: "provider_availability",
        id: provider,
        changed: [ "provider_availability" ],
        payload: {
          provider: provider,
          availability: for_user(user, provider, now: now)
        }
      )
    end

    def initialize(user:, provider:, now: Time.current)
      @user = user
      @provider = provider.to_s
      @now = now
    end

    def status
      return nil if user.blank? || provider.blank?

      usage_signal = usage_limit_signal
      return usage_limit_status(usage_signal) if usage_signal

      circuit = ProviderCircuitBreaker.call(provider, now: now)
      return nil unless circuit.open?
      return nil if circuit.usage_limit?

      {
        provider: provider,
        label: provider_label,
        model: circuit.model,
        state: "open",
        open: true,
        usage_exhausted: false,
        retry_after: circuit.retry_after&.iso8601,
        reason: circuit.reason.presence || "Provider appears temporarily unavailable.",
        message: transient_message(circuit)
      }
    end

    private

    attr_reader :user, :provider, :now

    UsageLimitSignal = Data.define(:run, :model, :reason)

    def usage_limit_status(signal)
      retry_after = (signal.run.finished_at || signal.run.updated_at || now) + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR
      {
        provider: provider,
        label: provider_label,
        model: signal.model,
        state: "exhausted",
        open: true,
        usage_exhausted: true,
        retry_after: retry_after.iso8601,
        reason: signal.reason,
        message: usage_limit_message(signal, retry_after)
      }
    end

    def usage_limit_message(signal, retry_after)
      model_text = signal.model.present? ? " for #{signal.model}" : ""
      reset_text = retry_after ? " Usage is expected to reset after #{retry_after.to_fs(:db)}." : ""
      "#{provider_label} usage limit reached#{model_text}. This item uses #{provider_label} until usage resets or you switch providers.#{reset_text}"
    end

    def transient_message(circuit)
      retry_text = circuit.retry_after ? " Retry after #{circuit.retry_after.to_fs(:db)}." : ""
      "#{provider_label} appears temporarily unavailable.#{retry_text}"
    end

    def usage_limit_signal
      usage_limit_failed_runs.filter_map do |run|
        text = diagnostic_text(run)
        next unless usage_limit?(run, text)

        UsageLimitSignal.new(
          run: run,
          model: ProviderUsageLimit.extract_model(text),
          reason: "Provider usage limit exhausted."
        )
      end.first
    end

    def usage_limit_failed_runs
      Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
         .includes(:run_diagnostic, :run_failure_classification)
         .where(user_id: user.id, state: "failed", agent_provider: provider)
         .where("runs.finished_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
         .order(finished_at: :desc, updated_at: :desc)
    end

    def usage_limit?(run, text)
      run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
        run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
        ProviderUsageLimit.detect?(text)
    end

    def diagnostic_text(run)
      [
        run.agent_outcome,
        run.run_failure_classification&.classification,
        run.run_diagnostic&.error_class,
        run.run_diagnostic&.error_message,
        run.job_logs.order(sequence: :desc).limit(5).pluck(:chunk).join(" ")
      ].compact.join(" ")
    end

    def provider_label
      App::Presentation.agent_provider_label(provider)
    end
  end
end
