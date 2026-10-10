module Runs
  class LifecyclePropagation
    def self.cancelled!(run) = new(run).cancelled!
    def self.failed!(run) = new(run).failed!
    def self.succeeded!(run) = new(run).succeeded!
    def self.terminal!(run) = new(run).terminal!
    def self.state_changed!(run) = new(run).state_changed!
    def self.wake_workflow_admission!(run) = new(run).wake_workflow_admission!

    def initialize(run)
      @run = run
    end

    # Operator-initiated stop: when a Run is cancelled mid-flight via the Stop
    # button, the chain can't continue. Cascade the cancel up to the Step and
    # Workflow so the whole burst goes terminal and the Workflow cleanup path
    # runs.
    def cancelled!
      request_live_process_kill!
      return unless step

      if step.may_cancel?
        step.cancel!
        step.save!
      end
      return unless step.reload.cancelled?

      workflow = step.workflow
      return unless workflow.may_cancel?

      workflow.cancel!
      workflow.save!
    end

    def failed!
      refresh_resource_summary_after_completion!
      classify_failure!
      cascade_failure_to_step!
      record_provider_failure_evidence!
      broadcast_provider_availability_after_failure!
    end

    def succeeded!
      clear_stale_failure_evidence!
      record_provider_success_evidence!
      broadcast_provider_availability_after_success!
    end

    def terminal!
      refresh_resource_summary_after_completion!
      wake_workflow_admission!
    end

    def wake_workflow_admission!
      wake_workflow_admission_after_completion!
    end

    def state_changed!
      WorkflowActivity.run_state_changed!(run)
    end

    private

    attr_reader :run

    delegate :step, :job, :user, :user_id, :agent_provider, :agent_outcome,
             :run_failure_classification, :run_diagnostic, :finished_at,
             :workflow_id, :job_id, to: :run

    def request_live_process_kill!
      run.spawned_processes.running.find_each do |process|
        process.request_kill!
      end
    rescue StandardError => e
      Rails.logger.warn("[Run##{run.id}] failed to request spawned process kill after cancellation: #{e.class}: #{e.message}")
    end

    def cascade_failure_to_step!
      return unless step
      return if scheduled_worker_died_step_retry?

      if step.may_fail?
        step.fail!
        step.save!
      end
      StepDispatcher.fail_from(step.reload) if step.failed?
    end

    def scheduled_worker_died_step_retry?
      return false if step.agentic?
      return false if step.kind.in?(Run::NON_IDEMPOTENT_IN_PLACE_RETRY_STEP_KINDS)

      classification = RunFailureClassifier.classify(run)
      return false unless classification.classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION

      workflow = step.workflow
      return false unless workflow

      attempt = nil
      scheduled_at = Time.current + worker_died_step_retry_jitter
      workflow.with_lock do
        workflow.reload
        return false if workflow.auto_retry_attempts.unskipped.where(run: run).exists?

        attempt_number = [
          prior_worker_died_step_attempts(workflow),
          prior_worker_died_step_failures
        ].max + 1
        return false if attempt_number > Run::WORKER_DIED_STEP_MAX_RETRIES

        attempt = AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: run.agent_provider.presence || workflow.agent_provider || job.agent_provider,
          failure_classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION,
          retry_kind: "failed_step",
          attempt_number: attempt_number,
          scheduled_at: scheduled_at
        )
      end

      WorkUnits::AutoRetryBackoff.record!(attempt)
      AutoRetryJob.set(wait_until: scheduled_at, priority: job.solid_queue_priority).perform_later(attempt.id)
      Rails.logger.info(
        "[Run##{run.id}] worker_died step retry #{attempt.attempt_number}/#{Run::WORKER_DIED_STEP_MAX_RETRIES}: " \
        "scheduled auto-retry attempt #{attempt.id} for step #{step.id} (#{step.kind}) at #{scheduled_at.iso8601}"
      )
      true
    rescue StandardError => e
      Rails.logger.warn("[Run##{run.id}] worker_died step retry scheduling failed: #{e.class}: #{e.message}")
      false
    end

    def worker_died_step_retry_jitter
      (run.id % (Run::WORKER_DIED_STEP_RETRY_JITTER_SECONDS + 1)).seconds
    end

    def prior_worker_died_step_failures
      step.runs
        .where.not(id: run.id)
        .where(state: "failed")
        .joins(:run_failure_classification)
        .where(run_failure_classifications: { classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION })
        .count
    end

    def prior_worker_died_step_attempts(workflow)
      AutoRetryAttempt.budget_scope_for(
        job: job,
        agent_provider: run.agent_provider.presence || workflow.agent_provider || job.agent_provider,
        failure_classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION
      ).where(run_id: step.runs.select(:id)).count
    end

    def classify_failure!
      @failure_classification_record = RunFailureClassifier.persist!(run)
    rescue StandardError => e
      Rails.logger.warn("[RunFailureClassifier] failed for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def clear_stale_failure_evidence!
      run_failure_classification&.destroy!
      run_diagnostic&.destroy!
      @failure_classification_record = nil
    rescue StandardError => e
      Rails.logger.warn("[Run##{run.id}] failed to clear stale failure evidence after success: #{e.class}: #{e.message}")
      nil
    end

    def record_provider_failure_evidence!
      return unless step.nil? || step.agentic?

      text = [
        agent_outcome,
        failure_classification_record&.classification,
        run_diagnostic&.error_class,
        run_diagnostic&.error_message
      ].compact.join(" ")
      if failure_classification_record&.classification == "provider_auth_expired"
        ProviderAvailabilityEvidence.record_invocation_auth_error!(
          run: run,
          message: text,
          observed_at: finished_at || Time.current
        )
        return
      end

      return if ProviderUsageLimit.inconclusive?(text)
      return unless agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
        failure_classification_record&.classification == ProviderUsageLimit::CLASSIFICATION ||
        ProviderUsageLimit.detect?(text)

      ProviderAvailabilityEvidence.record_invocation_usage_limit!(
        run: run,
        model: ProviderUsageLimit.extract_model(text),
        message: text,
        observed_at: finished_at || Time.current
      )
    rescue StandardError => e
      Rails.logger.warn("[ProviderAvailabilityEvidence] failed to record provider usage failure for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_provider_success_evidence!
      return unless agent_provider == "codex"
      return unless step.nil? || step.agentic?

      ProviderAvailabilityEvidence.record_codex_success!(
        user: user,
        source: "run_success",
        model: ProviderAvailabilityEvidence.codex_configured_model,
        run: run,
        observed_at: finished_at || Time.current,
        details: {
          outcome: agent_outcome,
          workflow_id: workflow_id,
          job_id: job_id,
          step_kind: step&.kind
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[ProviderAvailabilityEvidence] failed to record Codex success for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def broadcast_provider_availability_after_failure!
      return if agent_provider.blank?

      availability = App::ProviderAvailability.broadcast_changed(user: user, provider: agent_provider)
      retry_after = availability&.dig(:retry_after)
      ProviderAvailabilityBroadcastJob.set(wait_until: Time.zone.parse(retry_after)).perform_later(user_id, agent_provider) if retry_after.present?
    rescue StandardError => e
      Rails.logger.warn("[ProviderAvailability] failed to broadcast for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def broadcast_provider_availability_after_success!
      return if agent_provider.blank?

      App::ProviderAvailability.broadcast_changed(user: user, provider: agent_provider)
    rescue StandardError => e
      Rails.logger.warn("[ProviderAvailability] failed to broadcast success for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def refresh_resource_summary_after_completion!
      RunResourceSummary.refresh_for(run)
      run.association(:run_resource_summary).reset if run.association_cached?(:run_resource_summary)
    end

    def failure_classification_record
      @failure_classification_record || run_failure_classification
    end

    def wake_workflow_admission_after_completion!
      WorkflowAdmissionCapacityWakeupJob.perform_later if WorkflowAdmissionCapacityWakeup.deferred_sleepers_exist?
    rescue StandardError => e
      Rails.logger.warn("[WorkflowAdmissionCapacityWakeup] failed to enqueue after Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
