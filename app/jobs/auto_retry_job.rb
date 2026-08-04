class AutoRetryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(auto_retry_attempt_id)
    attempt = AutoRetryAttempt.includes(:job, :workflow, run: :claude_session).find(auto_retry_attempt_id)
    return if attempt.performed_at.present? || attempt.skipped_reason.present?

    if stale_attempt?(attempt)
      attempt.update!(skipped_reason: "source workflow was already superseded by a successful workflow")
      log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
      return
    end

    return if reschedule_if_provider_blocked(attempt)

    result = perform_retry(attempt)

    if result.success?
      attempt.update!(performed_at: Time.current)
      log(attempt, "auto-retry started via #{attempt.retry_kind}")
    elsif result.circuit&.open?
      reschedule_for_circuit(attempt, result.circuit)
    else
      attempt.update!(skipped_reason: result.error.presence || "retry could not be started")
      log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
    end
  end

  RETRY_DISPATCH = {
    "failed_step"        => :retry_failed_step,
    "resume_failed_step" => :resume_failed_step,
    "retry_workflow"     => :retry_workflow
  }.freeze

  private

  def reschedule_if_provider_blocked(attempt)
    circuit = ProviderCircuitBreaker.call(attempt.agent_provider)
    return false unless circuit.open?

    reschedule_for_circuit(attempt, circuit)
    true
  end

  def reschedule_for_circuit(attempt, circuit)
    retry_after = circuit.retry_after
    retry_after = Time.current + ProviderCircuitBreaker::OPEN_FOR unless retry_after && retry_after > Time.current

    attempt.update!(scheduled_at: retry_after)
    AutoRetryJob.set(wait_until: retry_after, priority: attempt.job.solid_queue_priority).perform_later(attempt.id)
    log(attempt, "auto-retry delayed until #{retry_after.iso8601}: #{circuit.reason}")
  end

  def perform_retry(attempt)
    send(RETRY_DISPATCH.fetch(attempt.retry_kind, :retry_workflow), attempt)
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
      RetryFailedStepEnqueuer.call(workflow: attempt.workflow)
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
    session = attempt.run&.claude_session
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
