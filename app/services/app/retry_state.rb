module App
  class RetryState
    CLASSIFICATION_KEYS = %w[
      failure_classification
      failure_classification_label
      classification
      classification_label
      failure_reason
    ].freeze
    RETRYABLE_KEYS = %w[failure_retryable retryable auto_retryable].freeze
    NEXT_RETRY_KEYS = %w[next_auto_retry_at auto_retry_at auto_retry_scheduled_at retry_at].freeze
    ATTEMPT_KEYS = %w[retry_attempt_count auto_retry_attempt_count retry_attempt attempts_used].freeze
    BUDGET_KEYS = %w[retry_budget_remaining auto_retry_budget_remaining retries_remaining budget_remaining].freeze
    EXHAUSTED_KEYS = %w[auto_retry_exhausted retry_exhausted retries_exhausted].freeze
    CIRCUIT_KEYS = %w[provider_circuit_open circuit_open provider_retry_delayed].freeze
    DELAYED_UNTIL_KEYS = %w[provider_circuit_until retry_delayed_until delayed_until circuit_open_until].freeze
    DELAY_REASON_KEYS = %w[retry_delay_reason provider_circuit_reason circuit_reason delay_reason].freeze

    UNSET = Object.new.freeze

    def self.for(job, latest_workflow: UNSET, latest_run: UNSET, latest_run_diagnostic: UNSET, any_active_run: UNSET)
      new(
        job,
        latest_workflow: latest_workflow,
        latest_run: latest_run,
        latest_run_diagnostic: latest_run_diagnostic,
        any_active_run: any_active_run
      ).as_json
    end

    def initialize(job, latest_workflow: UNSET, latest_run: UNSET, latest_run_diagnostic: UNSET, any_active_run: UNSET)
      @job = job
      @latest_workflow_override = latest_workflow
      @latest_run_override = latest_run
      @latest_run_diagnostic_override = latest_run_diagnostic
      @any_active_run_override = any_active_run
    end

    def as_json
      {
        classification: classification,
        classification_label: classification_label,
        retryable: retryable?,
        next_auto_retry_at: iso8601(next_auto_retry_at),
        retry_attempt_count: retry_attempt_count,
        retry_budget_remaining: retry_budget_remaining,
        retry_budget: retry_budget,
        auto_retry_exhausted: auto_retry_exhausted?,
        provider_circuit_open: provider_circuit_open?,
        retry_delayed_until: iso8601(retry_delayed_until),
        retry_delay_reason: retry_delay_reason,
        state_label: state_label
      }
    end

    private

    attr_reader :job

    def latest_workflow
      return job.latest_workflow if @latest_workflow_override.equal?(UNSET)

      @latest_workflow_override
    end

    def latest_run
      return job.current_run if @latest_run_override.equal?(UNSET)

      @latest_run_override
    end

    def latest_run_diagnostic
      return latest_failed_run&.run_diagnostic if @latest_run_diagnostic_override.equal?(UNSET)

      @latest_run_diagnostic_override
    end

    def latest_failed_workflow
      @latest_failed_workflow ||= begin
        workflow = latest_workflow
        workflow if workflow&.failed?
      end
    end

    def latest_failed_run
      @latest_failed_run ||= begin
        run = latest_run
        run if run&.failed?
      end
    end

    def artifacts
      @artifacts ||= latest_failed_workflow&.artifacts.to_h
    end

    def classification
      @classification ||= begin
        explicit = first_present(CLASSIFICATION_KEYS - [ "failure_reason" ])&.to_s&.presence
        explicit ||
          ("non_retryable_failure" if non_retryable_failure_text?) ||
          first_present([ "failure_reason" ])&.to_s&.presence
      end
    end

    def classification_label
      classification&.tr("_", " ")&.capitalize || "Unclassified"
    end

    def retryable?
      explicit = boolean_value(first_present(RETRYABLE_KEYS))
      return explicit unless explicit.nil?
      return false unless latest_failed_workflow || latest_failed_run
      return false if auto_retry_exhausted?
      return false if non_retryable_failure_text?

      job.open? && !any_active_run?
    end

    def next_auto_retry_at
      time_value(first_present(NEXT_RETRY_KEYS))
    end

    def any_active_run?
      if @any_active_run_override.equal?(UNSET)
        WorkUnits::TerminalWorkflowSync.for_job(job)
        return job.reload.active_runtime_work?
      end

      @any_active_run_override
    end

    def retry_attempt_count
      integer_value(first_present(ATTEMPT_KEYS)) || latest_failed_workflow&.failure_count || job.failure_count || 0
    end

    def retry_budget_remaining
      explicit = integer_value(first_present(BUDGET_KEYS))
      return explicit if explicit

      [ retry_budget - retry_attempt_count, 0 ].max
    end

    def retry_budget
      @retry_budget ||= AppSetting.max_job_failures
    end

    def auto_retry_exhausted?
      explicit = boolean_value(first_present(EXHAUSTED_KEYS))
      return explicit unless explicit.nil?

      job.closure_reason == "too_many_failures" || retry_attempt_count >= retry_budget
    end

    def provider_circuit_open?
      boolean_value(first_present(CIRCUIT_KEYS)) || retry_delayed_until.present?
    end

    def retry_delayed_until
      time_value(first_present(DELAYED_UNTIL_KEYS))
    end

    def retry_delay_reason
      first_present(DELAY_REASON_KEYS)&.to_s&.presence
    end

    def state_label
      return "Auto-retry exhausted" if auto_retry_exhausted?
      return "Provider circuit open" if provider_circuit_open?
      return "Retry scheduled" if next_auto_retry_at
      return "Retryable failure" if retryable?
      return "Waiting for operator" if latest_failed_workflow || latest_failed_run

      "No failure"
    end

    def non_retryable_failure_text?
      @non_retryable_failure_text ||= AutoRetryFailureClassifier.non_retryable_message?(failure_text)
    end

    def failure_text
      [
        job.landing_failure_reason,
        latest_failed_workflow&.failure_reason,
        artifacts["failure_reason"],
        latest_run_diagnostic&.error_class,
        latest_run_diagnostic&.error_message
      ].compact.join("\n")
    end

    def first_present(keys)
      keys.each do |key|
        value = artifacts[key]
        return value unless value.nil? || (value.respond_to?(:blank?) && value.blank?)
      end
      nil
    end

    def boolean_value(value)
      case value
      when true, false then value
      when "true", "1", 1 then true
      when "false", "0", 0 then false
      end
    end

    def integer_value(value)
      Integer(value, exception: false)
    end

    def time_value(value)
      return value if value.respond_to?(:iso8601)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
