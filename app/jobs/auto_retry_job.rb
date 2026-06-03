class AutoRetryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(auto_retry_attempt_id)
    attempt = AutoRetryAttempt.includes(:job, :workflow).find(auto_retry_attempt_id)
    return if attempt.performed_at.present? || attempt.skipped_reason.present?

    result = if attempt.retry_kind == "failed_step" && attempt.workflow.retry_available?
      RetryFailedStepEnqueuer.call(workflow: attempt.workflow)
    else
      RetryWorkflowEnqueuer.call(
        job: attempt.job,
        agent_provider: attempt.agent_provider,
        artifacts: { "auto_retry_attempt_id" => attempt.id },
        provider_validation: :none
      )
    end

    if result.success?
      attempt.update!(performed_at: Time.current)
      log(attempt, "auto-retry started via #{attempt.retry_kind}")
    else
      attempt.update!(skipped_reason: result.error.presence || "retry could not be started")
      log(attempt, "auto-retry skipped: #{attempt.skipped_reason}")
    end
  end

  private

  def log(attempt, message)
    run = attempt.job.runs.order(created_at: :desc).first
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  rescue StandardError
    nil
  end
end
