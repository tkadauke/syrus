require "set"

module App
  class ProviderAvailability
    CACHE_TTL = 2.minutes
    CACHE_VERSION = "v2"
    @cache_mutex = Mutex.new
    @process_cache = {}
    @shared_cache_keys = Set.new

    def self.for_user(user, provider, now: Time.current, cached: true)
      return new(user: user, provider: provider, now: now).status unless cached

      key = cache_key(user, provider)
      return nil unless key

      cache = Current.provider_availability_cache ||= {}
      return cache[key] if cache.key?(key)

      cache[key] = fetch_process_cache(key, now: now) do
        fetch_shared_cache(key) do
          new(user: user, provider: provider, now: now).status
        end
      end
    end

    def self.broadcast_changed(user:, provider:, now: Time.current)
      return unless user && provider.present?

      clear_cache!(user: user, provider: provider)
      availability = for_user(user, provider, now: now, cached: false)
      AppEvents.broadcast(
        user: user,
        type: "provider_availability.changed",
        resource: "provider_availability",
        id: provider,
        changed: [ "provider_availability" ],
        payload: {
          provider: provider,
          availability: availability
        }
      )
      availability
    end

    def self.clear_cache!(user: nil, provider: nil)
      cache = Current.provider_availability_cache
      unless user && provider.present?
        cache&.clear
        clear_process_cache!
        return
      end

      user_id = user.respond_to?(:id) ? user.id : user
      provider = provider.to_s
      cache&.delete_if { |(cached_user_id, cached_provider), _| cached_user_id == user_id && cached_provider == provider }
      delete_process_cache([ user_id, provider ])
      delete_shared_cache([ user_id, provider ])
    end

    def self.cache_key(user, provider)
      return if user.blank? || provider.blank?

      [ user.id, provider.to_s ]
    end

    def self.fetch_process_cache(key, now:)
      entry = @cache_mutex.synchronize do
        cached = @process_cache[key]
        cached if cached && cached[:expires_at] > now
      end
      return entry[:value] if entry

      value = yield
      @cache_mutex.synchronize do
        @process_cache[key] = { value: value, expires_at: now + CACHE_TTL }
      end
      value
    end

    def self.fetch_shared_cache(key)
      store_key = cache_store_key(key)
      @cache_mutex.synchronize { @shared_cache_keys.add(store_key) }
      wrapped = Rails.cache.read(store_key)
      return wrapped.fetch("value") if wrapped.is_a?(Hash) && wrapped.key?("value")

      value = yield
      Rails.cache.write(store_key, { "value" => value }, expires_in: CACHE_TTL)
      value
    rescue StandardError
      yield
    end

    def self.delete_process_cache(key)
      @cache_mutex.synchronize { @process_cache.delete(key) }
    end

    def self.delete_shared_cache(key)
      Rails.cache.delete(cache_store_key(key))
    rescue StandardError
      nil
    end

    def self.clear_process_cache!
      keys = @cache_mutex.synchronize do
        @process_cache = {}
        @shared_cache_keys.to_a
      end
      keys.each { |key| Rails.cache.delete(key) }
    rescue StandardError
      nil
    end

    def self.cache_store_key(key)
      user_id, provider = key
      "provider_availability/#{CACHE_VERSION}/users/#{user_id}/providers/#{provider}"
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

      latest_signal = latest_provider_run_signal
      return rate_limited_status(latest_signal) if latest_signal

      circuit = ProviderCircuitBreaker.call(provider, now: now, include_logs: false)
      return open_status(circuit) if circuit.open? && !circuit.usage_limit?

      available_status
    end

    def self.all_for_user(user, now: Time.current)
      User::AGENT_PROVIDERS.index_with { |provider| for_user(user, provider, now: now) }
    end

    private

    attr_reader :user, :provider, :now

    UsageLimitSignal = Data.define(:run, :model, :reason)
    RateLimitSignal = Data.define(:run, :reason)

    def open_status(circuit)
      {
        provider: provider,
        label: provider_label,
        model: circuit.model,
        state: "open",
        open: true,
        usage_exhausted: false,
        retry_after: circuit.retry_after&.iso8601,
        reason: circuit.reason.presence || "Provider appears temporarily unavailable.",
        message: transient_message(circuit),
        usage: usage_snapshot
      }
    end

    def available_status
      usage = usage_snapshot
      return nil unless usage

      {
        provider: provider,
        label: provider_label,
        model: nil,
        state: "available",
        open: false,
        usage_exhausted: false,
        retry_after: nil,
        reason: nil,
        message: "#{provider_label} is available.",
        usage: usage
      }
    end

    def rate_limited_status(signal)
      retry_after = (signal.run.finished_at || signal.run.updated_at || now) + ProviderCircuitBreaker::OPEN_FOR
      {
        provider: provider,
        label: provider_label,
        model: nil,
        state: "rate_limited",
        open: true,
        usage_exhausted: false,
        retry_after: retry_after.iso8601,
        reason: signal.reason,
        message: "#{provider_label} is rate-limited. Syrus will treat #{provider_label} as unavailable until a later #{provider_label} run completes without a rate-limit failure.",
        usage: usage_snapshot
      }
    end

    def usage_limit_status(signal)
      retry_after = ProviderQuotaReset.retry_after_for_run(signal.run, now: now) ||
        (signal.run.finished_at || signal.run.updated_at || now) + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR
      {
        provider: provider,
        label: provider_label,
        model: signal.model,
        state: "exhausted",
        open: true,
        usage_exhausted: true,
        retry_after: retry_after.iso8601,
        reason: signal.reason,
        message: usage_limit_message(signal, retry_after),
        usage: usage_snapshot
      }
    end

    def usage_limit_message(signal, retry_after)
      model_text = signal.model.present? ? " for #{signal.model}" : ""
      reset_text = retry_after ? " Usage is expected to reset after #{retry_after.to_fs(:db)}." : ""
      "#{provider_label} usage limit reached#{model_text}. This item uses #{provider_label} until usage resets.#{reset_text}"
    end

    def transient_message(circuit)
      retry_text = circuit.retry_after ? " Retry after #{circuit.retry_after.to_fs(:db)}." : ""
      "#{provider_label} appears temporarily unavailable.#{retry_text}"
    end

    def usage_limit_signal
      usage_limit_failed_runs.filter_map do |run|
        text = diagnostic_text(run)
        next unless usage_limit?(run, text)
        retry_after = ProviderQuotaReset.retry_after_for_run(run, now: now)
        next if retry_after && retry_after <= now

        UsageLimitSignal.new(
          run: run,
          model: ProviderUsageLimit.extract_model(text),
          reason: "Provider usage limit exhausted."
        )
      end.first
    end

    def latest_provider_run_signal
      run = latest_terminal_provider_run
      return unless run&.failed?

      text = diagnostic_text(run)
      return unless rate_limited?(run, text)

      RateLimitSignal.new(run: run, reason: "Latest #{provider_label} run hit a rate limit.")
    end

    def latest_terminal_provider_run
      Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
         .includes(:run_diagnostic, :run_failure_classification)
         .where(user_id: user.id, agent_provider: provider, state: %w[succeeded failed])
         .where.not(finished_at: nil)
         .order(finished_at: :desc, updated_at: :desc, id: :desc)
         .first
    end

    def usage_limit_failed_runs
      Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
         .includes(:run_diagnostic, :run_failure_classification, :step)
         .where(user_id: user.id, state: "failed", agent_provider: provider)
         .where("runs.finished_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
         .order(finished_at: :desc, updated_at: :desc)
         .limit(50)
    end

    def usage_limit?(run, text)
      return true if run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME
      return false unless ProviderUsageLimit.run_can_exhaust_provider?(run)

      (
        run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
        ProviderUsageLimit.detect?(text)
      )
    end

    def rate_limited?(run, text)
      return true if run.agent_outcome.to_s.in?(%w[rate_limited rate_limit])
      return true if run.run_failure_classification&.classification == "rate_limited"

      text.match?(/rate[ -]?limit|too many requests|quota exceeded|429/i)
    end

    def diagnostic_text(run)
      [
        run.agent_outcome,
        run.run_failure_classification&.classification,
        run.run_diagnostic&.error_class,
        run.run_diagnostic&.error_message
      ].compact.join(" ")
    end

    def usage_snapshot
      return unless provider == "codex"

      snapshot = user.codex_usage_snapshot || {}
      windows = codex_usage_windows(snapshot)
      return if windows.blank? && snapshot["remaining_percent"].blank? && user.codex_usage_status.blank?

      {
        status: user.codex_usage_status,
        observed_at: user.codex_usage_observed_at&.iso8601,
        remaining_percent: snapshot["remaining_percent"],
        windows: windows
      }.compact
    end

    def codex_usage_windows(snapshot)
      [ snapshot["primary"], snapshot["secondary"] ].compact.each_with_object({}) do |window, memo|
        label = window["label"].to_s
        key = case label
        when "5h" then "five_hour"
        when "weekly" then "weekly"
        else next
        end
        memo[key] = {
          label: label,
          remaining_percent: window["remaining_percent"],
          used_percent: window["used_percent"],
          reset_at: window["reset_at"]
        }.compact
      end
    end

    def provider_label
      App::Presentation.agent_provider_label(provider)
    end
  end
end
