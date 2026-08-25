class AutoRetryJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(auto_retry_attempt_id)
    attempt = AutoRetryAttempt.includes(:job, :workflow, run: :provider_session).find(auto_retry_attempt_id)
    return if attempt.performed_at.present? || attempt.skipped_reason.present?

    if (reason = attempt.stale_pending_reason)
      attempt.skip_stale_pending!(reason)
      log(attempt, "auto-retry skipped: #{reason}")
      return
    end

    if stale_attempt?(attempt)
      attempt.update!(skipped_reason: "source workflow was already superseded by a successful workflow")
      WorkUnits::AutoRetryBackoff.clear!(attempt)
      log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
      return
    end

    return if skip_if_provider_delay_no_longer_matches(attempt)
    return if reschedule_if_provider_blocked(attempt)
    return if reschedule_if_active_work_owns_failed_step_retry(attempt)

    result = perform_retry(attempt)

    if result.success?
      attempt.update!(performed_at: Time.current)
      WorkUnits::AutoRetryBackoff.clear!(attempt, terminal_state: nil)
      log(attempt, "auto-retry started via #{attempt.retry_kind}")
    elsif retry_result_circuit(result)&.open?
      reschedule_for_circuit(attempt, retry_result_circuit(result))
    elsif retry_result_active_work_lock?(result)
      reschedule_for_active_work_lock_result(attempt, result)
    else
      attempt.update!(skipped_reason: result.error.presence || "retry could not be started")
      WorkUnits::AutoRetryBackoff.clear!(attempt)
      log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
    end
  rescue WorkUnits::Launcher::LockConflict => e
    reschedule_for_active_work_unit(attempt, e)
  end

  RETRY_DISPATCH = {
    "failed_step"        => :retry_failed_step,
    "resume_failed_step" => :resume_failed_step,
    "retry_workflow"     => :retry_workflow
  }.freeze
  ACTIVE_WORK_UNIT_RETRY_DELAY = 5.minutes

  private

  def reschedule_if_provider_blocked(attempt)
    circuit = ProviderCircuitBreaker.call(attempt.agent_provider, include_logs: false)
    return false unless circuit.open?

    reschedule_for_circuit(attempt, circuit)
    true
  end

  PROVIDER_DELAYED_CLASSIFICATIONS = [ "rate_limited", ProviderUsageLimit::CLASSIFICATION ].freeze

  def skip_if_provider_delay_no_longer_matches(attempt)
    return false unless PROVIDER_DELAYED_CLASSIFICATIONS.include?(attempt.failure_classification)
    return false unless attempt.run
    return false if trusted_provider_delay_attempt?(attempt)

    fresh = RunFailureClassifier.persist!(attempt.run)
    return false if fresh.classification == attempt.failure_classification

    attempt.update!(skipped_reason: "failure classification changed from #{attempt.failure_classification} to #{fresh.classification} before retry")
    WorkUnits::AutoRetryBackoff.clear!(attempt)
    log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
    WorkEngine::Reconciler.request(source: self.class.name, job: attempt.job)
    true
  rescue StandardError => e
    Rails.logger.warn("[AutoRetryJob] failed to refresh Run ##{attempt.run_id} failure classification: #{e.class}: #{e.message}")
    false
  end

  def trusted_provider_delay_attempt?(attempt)
    case attempt.failure_classification
    when "rate_limited"
      attempt.run.user&.gh_rate_limit_reset_at&.future?
    when ProviderUsageLimit::CLASSIFICATION
      ProviderQuotaReset.retry_after_for_run(attempt.run).present?
    else
      false
    end
  end

  def reschedule_for_circuit(attempt, circuit)
    retry_after = circuit.retry_after
    retry_after = Time.current + ProviderCircuitBreaker::OPEN_FOR unless retry_after && retry_after > Time.current

    attempt.update!(scheduled_at: retry_after)
    WorkUnits::AutoRetryBackoff.record!(attempt)
    AutoRetryJob.set(wait_until: retry_after, priority: attempt.job.solid_queue_priority).perform_later(attempt.id)
    log(attempt, "auto-retry delayed until #{retry_after.iso8601}: #{circuit.reason}")
  end

  def reschedule_for_active_work_unit(attempt, conflict)
    retry_after = Time.current + ACTIVE_WORK_UNIT_RETRY_DELAY

    attempt.update!(scheduled_at: retry_after)
    AutoRetryJob.set(wait_until: retry_after, priority: attempt.job.solid_queue_priority).perform_later(attempt.id)
    log(
      attempt,
      "auto-retry delayed until #{retry_after.iso8601}: " \
        "active WorkUnit ##{conflict.work_unit.id} owns #{conflict.lock_key}"
    )
  end

  def reschedule_if_active_work_owns_failed_step_retry(attempt)
    return false unless attempt.retry_kind.in?(%w[failed_step resume_failed_step])
    return false unless attempt.job

    owner = WorkUnits::Ownership.active_unit_for_lock_key("job:#{attempt.job_id}")
    return false unless owner
    return false if owner.workflow_id.present? && owner.workflow_id == attempt.workflow_id

    retry_after = Time.current + ACTIVE_WORK_UNIT_RETRY_DELAY
    attempt.update!(scheduled_at: retry_after)
    AutoRetryJob.set(wait_until: retry_after, priority: attempt.job.solid_queue_priority).perform_later(attempt.id)
    log(
      attempt,
      "auto-retry delayed until #{retry_after.iso8601}: " \
        "active WorkUnit ##{owner.id} owns job:#{attempt.job_id}"
    )
    true
  end

  def perform_retry(attempt)
    send(RETRY_DISPATCH.fetch(attempt.retry_kind, :retry_workflow), attempt)
  end

  def retry_result_circuit(result)
    result.circuit if result.respond_to?(:circuit)
  end

  def retry_result_active_work_lock?(result)
    result.respond_to?(:active_work_lock?) && result.active_work_lock?
  end

  def reschedule_for_active_work_lock_result(attempt, result)
    retry_after = Time.current + ACTIVE_WORK_UNIT_RETRY_DELAY

    attempt.update!(scheduled_at: retry_after)
    AutoRetryJob.set(wait_until: retry_after, priority: attempt.job.solid_queue_priority).perform_later(attempt.id)
    log(attempt, "auto-retry delayed until #{retry_after.iso8601}: #{result.error}")
  end

  def stale_attempt?(attempt)
    source = attempt.workflow
    return false unless source

    newer_successful_workflow?(attempt.job, source)
  end

  def newer_successful_workflow?(job, source)
    cutoff = source.finished_at || source.created_at
    return false unless cutoff

    job.workflows
       .where(state: "succeeded")
       .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, source.id)
       .exists?
  end

  def retry_failed_step(attempt)
    if attempt.workflow.retry_available?
      RetryFailedStepEnqueuer.call(
        workflow: attempt.workflow,
        disable_session_resume: attempt.failure_classification == "agent_resume_unavailable"
      )
    else
      retry_workflow(attempt)
    end
  end

  def retry_workflow(attempt)
    RetryWorkflowEnqueuer.call(
      job: attempt.job,
      agent_provider: attempt.agent_provider,
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      provider_validation: :none,
      automatic: true
    )
  end

  def resume_failed_step(attempt)
    session = attempt.run&.provider_session
    return retry_workflow(attempt) unless session && attempt.workflow.retry_available? && attempt.run.step&.agentic?

    RetryFailedStepEnqueuer.call(
      workflow: attempt.workflow,
      parent_session_id: session.session_id,
      prompt: Prompts::Resume.new.to_s,
      agent_provider: session.provider.presence || attempt.agent_provider
    )
  end

  def log(attempt, message)
    run = attempt.job.runs.order(created_at: :desc).first
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  rescue StandardError
    nil
  end
end
