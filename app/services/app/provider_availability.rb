module App
  class ProviderAvailability
    CACHE_TTL = 10.minutes
    @cache_mutex = Mutex.new
    @process_cache = {}

    def self.for_user(user, provider, now: Time.current, cached: true)
      return PerformanceLogging.phase("provider_availability.status", provider: provider, cached: false) { new(user: user, provider: provider, now: now).status } unless cached

      key = cache_key(user, provider)
      return nil unless key

      cache = Current.provider_availability_cache ||= {}
      return cache[key] if cache.key?(key)

      cache[key] = PerformanceLogging.phase("provider_availability.for_user", provider: provider, cached: true) do
        fetch_process_cache(key, now: now) do
          PerformanceLogging.phase("provider_availability.status", provider: provider, cached: true) { new(user: user, provider: provider, now: now).status }
        end
      end
    end

    def self.broadcast_changed(user:, provider:, now: Time.current)
      return unless user && provider.present?

      clear_cache!(user: user, provider: provider)
      # clear_cache!(user:, provider:) only busts this class's own
      # per-user cache. ProviderCircuitBreaker.call(..., include_logs: false)
      # keeps its own process-level cache (keyed by provider, 30s TTL) that
      # the `cached: false` below does NOT bypass — without this, a Run
      # failure/success recorded microseconds before this broadcast (the
      # common case: this method is called from that same Run's
      # after_update_commit callback) can read back a decision computed
      # just before the triggering evidence existed, and that stale
      # "closed" decision then sticks for retry gates (RetryWorkflowEnqueuer,
      # SmartRetryEnqueuer, etc.) for up to 30 more seconds regardless of
      # how many further failures land in that window.
      ProviderCircuitBreaker.clear_read_cache!
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

    def self.delete_process_cache(key)
      @cache_mutex.synchronize { @process_cache.delete(key) }
    end

    def self.clear_process_cache!
      @cache_mutex.synchronize do
        @process_cache = {}
      end
      ProviderCircuitBreaker.clear_read_cache!
    end

    def initialize(user:, provider:, now: Time.current)
      @user = user
      @provider = provider.to_s
      @now = now
    end

    def status
      PerformanceLogging.phase("provider_availability.compute", provider: provider) do
        compute_status
      end
    end

    def compute_status
      return nil if user.blank? || provider.blank?

      usage_signal = PerformanceLogging.phase("provider_availability.usage_limit_signal", provider: provider) { usage_limit_signal }
      return usage_limit_status(usage_signal) if usage_signal

      latest_signal = PerformanceLogging.phase("provider_availability.latest_provider_run_signal", provider: provider) { latest_provider_run_signal }
      return rate_limited_status(latest_signal) if latest_signal

      circuit = PerformanceLogging.phase("provider_availability.circuit_breaker", provider: provider) do
        ProviderCircuitBreaker.call(provider, now: now, include_logs: false)
      end
      return open_status(circuit) if circuit.open? && !circuit.usage_limit?

      available_status
    end

    def self.all_for_user(user, now: Time.current)
      PerformanceLogging.phase("provider_availability.all_for_user") do
        User.agent_providers.index_with do |provider|
          PerformanceLogging.phase("provider_availability.all_for_user.provider", provider: provider) do
            for_user(user, provider, now: now)
          end
        end
      end
    end

    private

    attr_reader :user, :provider, :now

    UsageLimitSignal = Data.define(:run, :model, :reason, :evidence)
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
        usage: usage_snapshot,
        evidence: latest_evidence_payload
      }.merge(pause_metadata)
    end

    def available_status
      usage = usage_snapshot
      evidence = latest_evidence_payload
      return nil if usage.blank? && evidence.blank?

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
        usage: usage,
        evidence: evidence
      }.merge(pause_metadata)
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
        usage: usage_snapshot,
        evidence: latest_evidence_payload
      }.merge(pause_metadata)
    end

    def usage_limit_status(signal)
      retry_after = retry_after_for_usage_signal(signal)
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
        usage: usage_snapshot,
        evidence: latest_evidence_payload(primary: usage_signal_summary(signal))
      }.merge(pause_metadata)
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
      evidence = current_usage_limit_evidence
      if evidence
        return UsageLimitSignal.new(
          run: evidence.run,
          model: evidence.model,
          reason: usage_limit_reason_for_evidence(evidence),
          evidence: evidence
        )
      end

      usage_limit_failed_runs.filter_map do |run|
        next if run.run_failure_classification&.repaired_for_circuit?

        text = diagnostic_text(run)
        next unless usage_limit?(run, text)
        retry_after = ProviderQuotaReset.retry_after_for_run(run, now: now)
        next if retry_after && retry_after <= now
        model = ProviderUsageLimit.extract_model(text)
        observed_at = run.finished_at || run.updated_at || now
        next if provider == "codex" && ProviderAvailabilityEvidence.suppressed_by_positive_after?(
          user: user,
          provider: provider,
          account_id: CodexAccountScope.for_user(user),
          model: model,
          observed_at: observed_at
        )

        UsageLimitSignal.new(
          run: run,
          model: model,
          reason: "Provider usage limit exhausted.",
          evidence: nil
        )
      end.first
    end

    def current_usage_limit_evidence
      ProviderAvailabilityEvidence
        .where(user: user, provider: provider, status: "exhausted")
        .unrepaired_for_circuit
        .where("observed_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
        .recent
        .detect do |evidence|
          next false if false_positive_codex_evidence?(evidence)
          next false if usage_evidence_reset_at(evidence)&.<= now

          !ProviderAvailabilityEvidence.suppressed_by_positive_after?(
            user: user,
            provider: provider,
            account_id: evidence.account_id,
            model: evidence.model,
            observed_at: evidence.observed_at
          )
        end
    end

    def false_positive_codex_evidence?(evidence)
      ProviderAvailabilityEvidence.false_positive_codex_usage_limit?(
        evidence.details&.dig("message"),
        model: evidence.model
      )
    end

    def usage_limit_reason_for_evidence(evidence)
      source = evidence.source.to_s.humanize(capitalize: false)
      "Provider usage limit exhausted (#{source})."
    end

    def latest_provider_run_signal
      run = latest_terminal_provider_run
      return unless run&.failed?
      return if run.run_failure_classification&.repaired_for_circuit?

      text = diagnostic_text(run)
      return unless rate_limited?(run, text)

      RateLimitSignal.new(run: run, reason: "Latest #{provider_label} run hit a rate limit.")
    end

    def latest_terminal_provider_run
      run = provider_run_scope_for_latest
        .select(:id, :state, :finished_at, :updated_at)
        .where(state: %w[succeeded failed])
        .where.not(finished_at: nil)
        .order(finished_at: :desc, updated_at: :desc, id: :desc)
        .limit(1)
        .first
      return run unless run&.failed?

      Run.includes(:run_diagnostic, :run_failure_classification).find(run.id)
    end

    def usage_limit_failed_runs
      provider_run_scope.left_outer_joins(:run_diagnostic, :run_failure_classification)
         .select(:id, :job_id, :step_id, :user_id, :agent_provider, :state, :agent_outcome, :finished_at, :updated_at)
         .includes(:run_diagnostic, :run_failure_classification, :step)
         .where(state: "failed")
         .where("runs.finished_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
         .order(finished_at: :desc, updated_at: :desc)
         .limit(50)
    end

    def provider_run_scope
      Run.where(user_id: user.id, agent_provider: provider)
    end

    def provider_run_scope_for_latest
      scope = provider_run_scope
      return scope unless ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")

      scope.from(Arel.sql("#{Run.quoted_table_name} FORCE INDEX (idx_runs_provider_latest_finished)"))
    end

    def usage_limit?(run, text)
      return false if run.run_failure_classification&.repaired_for_circuit?
      return false if ProviderUsageLimit.inconclusive?(text)
      return true if run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME
      return false unless ProviderUsageLimit.run_can_exhaust_provider?(run)

      (
        run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
        ProviderUsageLimit.detect?(text)
      )
    end

    def rate_limited?(run, text)
      return true if ProviderRateLimitEvidence::OUTCOMES.include?(run.agent_outcome.to_s)
      if run.run_failure_classification&.classification == "rate_limited"
        return true if ProviderRateLimitEvidence.direct?(run, text: text, include_logs: false, provider_only: true)
        return true if classified_from_rate_limited_log?(run)
      end

      ProviderRateLimitEvidence.direct?(run, text: text, include_logs: false, provider_only: true)
    end

    def classified_from_rate_limited_log?(run)
      return false unless run.step.nil? || run.step&.agentic? == true

      Array(run.run_failure_classification&.classifier_inputs&.fetch("job_log_kinds", [])).include?("rate_limited")
    end

    def diagnostic_text(run)
      [
        run.agent_outcome,
        run.run_diagnostic&.error_class,
        run.run_diagnostic&.error_message
      ].compact.join(" ")
    end

    def usage_snapshot
      PerformanceLogging.phase("provider_availability.usage_snapshot", provider: provider) do
        snapshot = usage_snapshot_source
        windows = usage_windows(snapshot)
        evidence = latest_usage_evidence
        status = usage_status(evidence)
        observed_at = usage_observed_at(evidence)
        remaining_percent = usage_remaining_percent(snapshot)
        return if windows.blank? && snapshot["remaining_percent"].blank? && status.blank? && evidence.blank?

        {
          status: status,
          observed_at: observed_at,
          remaining_percent: remaining_percent,
          windows: windows,
          evidence: evidence&.summary
        }.compact
      end
    end

    def latest_evidence_payload(primary: nil)
      PerformanceLogging.phase("provider_availability.latest_evidence_payload", provider: provider) do
        current = primary || latest_evidence&.summary
        return if current.blank? && latest_positive_evidence.blank? && latest_negative_evidence.blank?

        {
          current: current,
          latest_positive: evidence_summary_if_not_older_than(latest_positive_evidence, current),
          latest_negative: evidence_summary_if_not_older_than(latest_negative_evidence, current)
        }.compact
      end
    end

    def pause_metadata
      observed_at = latest_evidence&.observed_at || (user.codex_usage_observed_at if provider == "codex")
      {
        pause_threshold_percent: user.provider_availability_pause_threshold_for(provider),
        pause_enabled: user.provider_availability_pause_enabled?(provider),
        override_active: user.provider_availability_overridden?(provider, evidence_observed_at: observed_at)
      }
    end

    def evidence_summary_if_not_older_than(evidence, current)
      return unless evidence
      current_time = parse_observed_at(current&.dig(:observed_at) || current&.dig("observed_at"))
      evidence.summary if current_time.blank? || evidence.observed_at >= current_time
    end

    def parse_observed_at(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def usage_signal_summary(signal)
      return signal.evidence.summary if signal.evidence
      return unless signal.run

      observed_at = signal.run.finished_at || signal.run.updated_at
      {
        status: "exhausted",
        source: "failed_run",
        observed_at: observed_at&.iso8601,
        provider: provider,
        account_id: CodexAccountScope.for_user(user),
        model: signal.model,
        run_id: signal.run.id,
        details: {
          agent_outcome: signal.run.agent_outcome,
          failure_classification: signal.run.run_failure_classification&.classification
        }.compact,
        repair: signal.run.run_failure_classification&.repair_summary
      }.compact
    end

    def latest_evidence
      @latest_evidence ||= latest_displayable_evidence(ProviderAvailabilityEvidence.where(user: user, provider: provider))
    end

    def latest_positive_evidence
      @latest_positive_evidence ||= ProviderAvailabilityEvidence.where(user: user, provider: provider).positive.recent.first
    end

    def latest_negative_evidence
      @latest_negative_evidence ||= latest_displayable_evidence(ProviderAvailabilityEvidence.where(user: user, provider: provider).negative)
    end

    def latest_usage_evidence
      @latest_usage_evidence ||= latest_displayable_evidence(
        ProviderAvailabilityEvidence.where(user: user, provider: provider, source: ProviderAvailabilityEvidence::PROBE_SOURCES)
      )
    end

    def latest_displayable_evidence(scope)
      scope.recent.detect { |evidence| !false_positive_codex_evidence?(evidence) }
    end

    def retry_after_for_usage_signal(signal)
      if signal.run
        return ProviderQuotaReset.retry_after_for_run(signal.run, now: now) ||
          (signal.run.finished_at || signal.run.updated_at || now) + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR
      end

      usage_evidence_reset_at(signal.evidence) ||
        (signal.evidence&.observed_at || now) + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR
    end

    def usage_evidence_reset_at(evidence)
      return codex_evidence_reset_at(evidence) if evidence&.provider == "codex"
      return claude_evidence_reset_at(evidence) if evidence&.provider == "claude"
    end

    def codex_evidence_reset_at(evidence)
      snapshot = evidence&.details&.dig("snapshot") || {}
      windows = [
        snapshot["primary"],
        snapshot["secondary"],
        snapshot.dig("spend_control", "individual_limit"),
        *Array(snapshot["additional_rate_limits"]).flat_map { |entry| [ entry["primary"], entry["secondary"] ] }
      ].compact
      reset_values = windows.filter_map { |window| window["reset_at"].presence }
      return if reset_values.blank?

      Time.zone.parse(reset_values.min) + ProviderQuotaReset::RETRY_BUFFER
    rescue ArgumentError, TypeError
      nil
    end

    def claude_evidence_reset_at(evidence)
      snapshot = evidence&.details&.dig("snapshot") || {}
      minutes = [
        snapshot["session_reset_minutes"],
        snapshot["weekly_reset_minutes"]
      ].compact.min
      return if minutes.blank?

      evidence.observed_at + Float(minutes).minutes + ProviderQuotaReset::RETRY_BUFFER
    rescue ArgumentError, TypeError
      nil
    end

    def usage_snapshot_source
      return user.codex_usage_snapshot || {} if provider == "codex"

      latest_usage_evidence&.details&.dig("snapshot") || {}
    end

    def usage_status(evidence)
      return user.codex_usage_status.presence || evidence&.status if provider == "codex"

      evidence&.status
    end

    def usage_observed_at(evidence)
      return user.codex_usage_observed_at&.iso8601 || evidence&.observed_at&.iso8601 if provider == "codex"

      evidence&.observed_at&.iso8601
    end

    def usage_remaining_percent(snapshot)
      return snapshot["remaining_percent"] if snapshot["remaining_percent"].present?

      used_percentages = [ snapshot["session_pct"], snapshot["weekly_pct"] ].compact
      return if used_percentages.blank?

      (100.0 - used_percentages.max.to_f).clamp(0.0, 100.0).round(1)
    end

    def usage_windows(snapshot)
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
        .merge(claude_usage_windows(snapshot))
    end

    def claude_usage_windows(snapshot)
      [
        [ "five_hour", "5h", snapshot["session_pct"], snapshot["session_reset_minutes"] ],
        [ "weekly", "weekly", snapshot["weekly_pct"], snapshot["weekly_reset_minutes"] ]
      ].each_with_object({}) do |(key, label, used_percent, reset_minutes), memo|
        next if used_percent.blank?

        memo[key] = {
          label: label,
          remaining_percent: (100.0 - used_percent.to_f).clamp(0.0, 100.0).round(1),
          used_percent: used_percent,
          reset_at: reset_time_from_minutes(reset_minutes)
        }.compact
      end
    end

    def reset_time_from_minutes(minutes)
      return if minutes.blank?

      (now + Float(minutes).minutes).iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def provider_label
      App::Presentation.agent_provider_label(provider)
    end
  end
end
