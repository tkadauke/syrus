class AutoRetryScheduler
  MAX_ATTEMPTS = 3
  BACKOFFS = [ 5.minutes, 20.minutes, 1.hour ].freeze

  WORKER_DIED_CLASSIFICATION = "worker_died"
  MAX_WORKER_DIED_ATTEMPTS = 20
  WORKER_DIED_BACKOFF = 30.seconds

  def self.schedule_for_workflow(...) = new(...).schedule_for_workflow

  def initialize(workflow:)
    @workflow = workflow
  end

  def schedule_for_workflow
    return unless workflow.failed?
    WorkEngine::Reconciler.request(source: self.class.name, job: workflow.job, workflow: workflow)
    log("auto-retry skipped: unified work-engine reconciler handles retry scheduling")
    return

    return if pending_attempt_exists?

    if workflow.artifact("main_broken")
      log("auto-retry skipped: main branch broken; workflow will resume once main is fixed")
      return
    end

    classification = AutoRetryFailureClassifier.call(workflow: workflow)
    unless classification.retryable?
      log("auto-retry skipped: #{classification.reason}")
      return
    end

    run = latest_failed_run
    agent_provider = run&.agent_provider.presence || workflow.agent_provider
    worker_died = classification.classification == WORKER_DIED_CLASSIFICATION
    attempt_number = next_attempt_number(agent_provider, classification.classification)
    max_attempts = worker_died ? MAX_WORKER_DIED_ATTEMPTS : MAX_ATTEMPTS
    if attempt_number > max_attempts
      log("auto-retry skipped: budget exhausted for #{agent_provider}/#{classification.classification}")
      return
    end

    retry_kind = retry_kind_for(run, classification)
    return if retry_kind.nil?

    backoff = worker_died ? WORKER_DIED_BACKOFF : BACKOFFS.fetch(attempt_number - 1)
    attempt = AutoRetryAttempt.create!(
      job: workflow.job,
      workflow: workflow,
      run: run,
      agent_provider: agent_provider,
      failure_classification: classification.classification,
      retry_kind: retry_kind,
      attempt_number: attempt_number,
      scheduled_at: Time.current + backoff
    )

    AutoRetryJob.set(wait_until: attempt.scheduled_at, priority: workflow.job.solid_queue_priority).perform_later(attempt.id)
    log("auto-retry scheduled in #{backoff.inspect} via #{retry_kind}")
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

  def pending_attempt_exists?
    workflow.auto_retry_attempts.where(performed_at: nil, skipped_reason: nil).exists?
  end

  def retry_workflow_safe?
    workflow.retry_as_new_workflow_available? &&
      workflow.job.open? &&
      !workflow.job.any_active_run? &&
      !workflow.landing_workflow?
  end

  def retry_kind_for(run, classification)
    return "failed_step" if classification.classification == "agent_resume_unavailable" && workflow.retry_available?
    return "resume_failed_step" if workflow.retry_available? && resumable_agent_run?(run)
    return "failed_step" if workflow.retry_available?
    return "retry_workflow" if retry_workflow_safe?

    nil
  end

  def resumable_agent_run?(run)
    run&.step&.agentic? && run.claude_session.present?
  end

  def log(message)
    run = latest_failed_run || workflow.runs.order(created_at: :desc).first
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  rescue StandardError
    nil
  end
end
