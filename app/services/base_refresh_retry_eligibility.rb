class BaseRefreshRetryEligibility
  RECOVERABLE_BLOCKED_CLASSIFICATIONS = %w[
    disk_full
    storage_unavailable
    worker_died
    worker_died_under_resource_pressure
  ].freeze

  Result = Data.define(:eligible, :workflow, :checkpoint, :message) do
    def eligible? = eligible
  end

  def self.call(...) = new(...).call

  def initialize(job:, source_workflow_id: nil)
    @job = job
    @source_workflow_id = source_workflow_id
  end

  def call
    workflow = source_workflow
    return failure("The selected source workflow is not a failed or strictly eligible blocked workflow for this Job.") unless workflow
    return failure("The selected blocked workflow still has queued or running Runs.") if workflow.blocked? && workflow.runs.active.exists?
    if workflow.blocked? && (WorkUnits::Ownership.active_for_job?(job) || WorkUnits::Ownership.retained_locks_for_job?(job))
      return failure("The selected blocked workflow still has active WorkUnit ownership or retained mutation locks.")
    end
    if workflow.blocked? && (blocked_failure = blocked_failure_message(workflow))
      return failure(blocked_failure)
    end

    retry_eligibility = RetryWorkflowEligibility.call(job: job)
    return failure(retry_eligibility.message) unless retry_eligibility.eligible?

    checkpoint = RunCheckpoint.published.where(workflow_id: workflow.id).recent.first
    return failure("No published mutation checkpoint is available for the selected source workflow.") unless checkpoint
    if workflow.blocked? && (checkpoint_failure = blocked_checkpoint_failure(checkpoint, workflow))
      return checkpoint_failure
    end

    Result.new(eligible: true, workflow: workflow, checkpoint: checkpoint, message: nil)
  rescue RepositoryContent::Error => e
    failure("The published checkpoint or current effective base could not be resolved: #{e.message}")
  end

  private

  attr_reader :job, :source_workflow_id

  def effective_base_repository
    job.base_on_upstream_default? ? job.base_repository : job.repository
  end

  def blocked_checkpoint_failure(checkpoint, workflow)
    unless checkpoint.job_id == job.id && checkpoint.workflow_id == workflow.id &&
        checkpoint.run&.workflow_id == workflow.id && checkpoint.run&.job_id == job.id
      return failure("The published checkpoint provenance does not match the selected Job and Workflow.")
    end
    return failure("The published checkpoint has no commit SHA or durable remote ref.") if checkpoint.commit_sha.blank? || checkpoint.remote_ref.blank?

    revision = RepositoryContent.for(checkpoint.repository, user: job.user).resolve(checkpoint.remote_ref, max_age: 0)
    return failure("The published checkpoint ref does not resolve to its recorded commit SHA.") unless revision.id == checkpoint.commit_sha

    base_ref = job.effective_base_branch.to_s.presence
    return failure("The Job has no effective base ref to refresh onto.") unless base_ref

    RepositoryContent.for(effective_base_repository, user: job.user).resolve(base_ref, max_age: 0)
    nil
  end

  def blocked_failure_message(workflow)
    classifications = RunFailureClassification.where(run_id: workflow.runs.failed.select(:id)).to_a
    return "The selected blocked workflow has no structured recoverable infrastructure failure evidence." if classifications.empty?

    unsafe = classifications.reject do |classification|
      classification.retryable && RECOVERABLE_BLOCKED_CLASSIFICATIONS.include?(classification.classification)
    end
    return if unsafe.empty?

    "The selected blocked workflow contains semantic or ambiguous failure evidence and requires operator review."
  end

  def source_workflow
    scope = job.workflows.where(state: %w[failed blocked])
    return scope.find_by(id: source_workflow_id) if source_workflow_id.present?

    scope.order(Arel.sql("CASE state WHEN 'failed' THEN 0 ELSE 1 END"), created_at: :desc, id: :desc).first
  end

  def failure(message)
    Result.new(eligible: false, workflow: nil, checkpoint: nil, message: message)
  end
end
