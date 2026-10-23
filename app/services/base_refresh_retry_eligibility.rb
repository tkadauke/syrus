class BaseRefreshRetryEligibility
  Result = Data.define(:eligible, :workflow, :checkpoint, :message) do
    def eligible? = eligible
  end

  def self.call(...) = new(...).call

  def initialize(job:, source_workflow_id: nil)
    @job = job
    @source_workflow_id = source_workflow_id
  end

  def call
    retry_eligibility = RetryWorkflowEligibility.call(job: job)
    return failure(retry_eligibility.message) unless retry_eligibility.eligible?

    workflow = source_workflow
    return failure("The selected source workflow is not a failed workflow for this Job.") unless workflow&.failed?

    checkpoint = RunCheckpoint.published.where(workflow_id: workflow.id).recent.first
    return failure("No published mutation checkpoint is available for the selected failed workflow.") unless checkpoint

    Result.new(eligible: true, workflow: workflow, checkpoint: checkpoint, message: nil)
  end

  private

  attr_reader :job, :source_workflow_id

  def source_workflow
    scope = job.workflows.where(state: "failed")
    return scope.find_by(id: source_workflow_id) if source_workflow_id.present?

    scope.order(created_at: :desc, id: :desc).first
  end

  def failure(message)
    Result.new(eligible: false, workflow: nil, checkpoint: nil, message: message)
  end
end
