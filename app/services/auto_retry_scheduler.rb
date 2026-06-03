class AutoRetryScheduler
  MAX_ATTEMPTS = 3
  BACKOFFS = [ 5.minutes, 20.minutes, 1.hour ].freeze

  def self.schedule_for_workflow(...) = new(...).schedule_for_workflow

  def initialize(workflow:)
    @workflow = workflow
  end

  def schedule_for_workflow
    return unless workflow.failed?

    classification = AutoRetryFailureClassifier.call(workflow: workflow)
    unless classification.retryable?
      log("auto-retry skipped: #{classification.reason}")
      return
    end

    run = latest_failed_run
    agent_provider = run&.agent_provider.presence || workflow.agent_provider
    attempt_number = next_attempt_number(agent_provider, classification.classification)
    if attempt_number > MAX_ATTEMPTS
      log("auto-retry skipped: budget exhausted for #{agent_provider}/#{classification.classification}")
      return
    end

    retry_kind = workflow.retry_available? ? "failed_step" : "retry_workflow"
    return unless retry_kind == "failed_step" || retry_workflow_safe?

    attempt = AutoRetryAttempt.create!(
      job: workflow.job,
      workflow: workflow,
      run: run,
      agent_provider: agent_provider,
      failure_classification: classification.classification,
      retry_kind: retry_kind,
      attempt_number: attempt_number,
      scheduled_at: Time.current + BACKOFFS.fetch(attempt_number - 1)
    )

    AutoRetryJob.set(wait_until: attempt.scheduled_at, priority: workflow.job.solid_queue_priority).perform_later(attempt.id)
    log("auto-retry scheduled in #{BACKOFFS.fetch(attempt_number - 1).inspect} via #{retry_kind}")
    attempt
  rescue StandardError => e
    Rails.logger.warn("[AutoRetryScheduler] workflow ##{workflow&.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :workflow

  def latest_failed_run
    workflow.runs.where(state: "failed").order(created_at: :desc).first
  end

  def next_attempt_number(agent_provider, failure_classification)
    AutoRetryAttempt.budget_scope_for(
      job: workflow.job,
      agent_provider: agent_provider,
      failure_classification: failure_classification
    ).count + 1
  end

  def retry_workflow_safe?
    workflow.retry_as_new_workflow_available? &&
      workflow.job.open? &&
      !workflow.job.any_active_run? &&
      workflow.trigger_kind != "auto_merge"
  end

  def log(message)
    run = latest_failed_run || workflow.runs.order(created_at: :desc).first
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  rescue StandardError
    nil
  end
end
