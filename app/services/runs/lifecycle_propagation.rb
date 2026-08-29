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
      cascade_failure_to_step!
      classify_failure!
      record_provider_failure_evidence!
      broadcast_provider_availability_after_failure!
    end

    def succeeded!
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

    def cascade_failure_to_step!
      return unless step
      return if retried_in_place_after_worker_died?

      if step.may_fail?
        step.fail!
        step.save!
      end
      StepDispatcher.fail_from(step.reload) if step.failed?
    end

    def retried_in_place_after_worker_died?
      return false if step.agentic?
      return false if step.kind.in?(Run::NON_IDEMPOTENT_IN_PLACE_RETRY_STEP_KINDS)

      classification = RunFailureClassifier.classify(run)
      return false unless classification.classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION

      prior_worker_died_count = step.runs
        .where.not(id: run.id)
        .where(state: "failed")
        .joins(:run_failure_classification)
        .where(run_failure_classifications: { classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION })
        .count

      return false unless prior_worker_died_count < Run::WORKER_DIED_STEP_MAX_RETRIES

      StepDispatcher.create_run_and_enqueue(step, step.workflow)
      Rails.logger.info(
        "[Run##{run.id}] worker_died in-place retry #{prior_worker_died_count + 1}/#{Run::WORKER_DIED_STEP_MAX_RETRIES}: " \
        "new run queued on step #{step.id} (#{step.kind})"
      )
      true
    rescue StandardError => e
      Rails.logger.warn("[Run##{run.id}] worker_died in-place retry failed: #{e.class}: #{e.message}")
      false
    end

    def classify_failure!
      @failure_classification_record = RunFailureClassifier.persist!(run)
    rescue StandardError => e
      Rails.logger.warn("[RunFailureClassifier] failed for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_provider_failure_evidence!
      return unless agent_provider == "codex"
      return unless step.nil? || step.agentic?

      text = [
        agent_outcome,
        failure_classification_record&.classification,
        run_diagnostic&.error_class,
        run_diagnostic&.error_message
      ].compact.join(" ")
      return if ProviderUsageLimit.inconclusive?(text)
      return unless agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
        failure_classification_record&.classification == ProviderUsageLimit::CLASSIFICATION ||
        ProviderUsageLimit.detect?(text)

      ProviderAvailabilityEvidence.record_codex_invocation_failure!(
        run: run,
        model: ProviderUsageLimit.extract_model(text),
        message: text,
        observed_at: finished_at || Time.current
      )
    rescue StandardError => e
      Rails.logger.warn("[ProviderAvailabilityEvidence] failed to record Codex failure for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_provider_success_evidence!
      return unless agent_provider == "codex"
      return unless step.nil? || step.agentic?

      ProviderAvailabilityEvidence.record_codex_success!(
        user: user,
        source: "run_success",
        model: CodexInvocation.configured_model,
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
