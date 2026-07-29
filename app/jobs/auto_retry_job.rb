class AutoRetryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(auto_retry_attempt_id)
    attempt = AutoRetryAttempt.includes(:job, :workflow, run: :claude_session).find(auto_retry_attempt_id)
    return if attempt.performed_at.present? || attempt.skipped_reason.present?

    result = perform_retry(attempt)

    if result.success?
      attempt.update!(performed_at: Time.current)
      log(attempt, "auto-retry started via #{attempt.retry_kind}")
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

  def perform_retry(attempt)
    send(RETRY_DISPATCH.fetch(attempt.retry_kind, :retry_workflow), attempt)
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
