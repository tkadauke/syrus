class RetryFailedStepEnqueuer
  Result = Data.define(:run, :workflow, :step, :error) do
    def success? = run.present?
  end

  def self.call(...) = new(...).call

  def initialize(workflow:)
    @workflow = workflow
  end

  def call
    return failure("Workflow is not in a failed state.") unless workflow.failed?
    return failure("Workspace already cleaned up - use Start over.") unless workflow.retry_available?

    failed_step = workflow.steps.where(state: "failed").order(:position).first
    return failure("No failed step to retry.") unless failed_step

    workflow.reopen!
    workflow.save!
    failed_step.reopen!
    failed_step.save!

    run = failed_step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )

    Result.new(run: run, workflow: workflow, step: failed_step, error: nil)
  end

  private

  attr_reader :workflow

  def failure(message)
    Result.new(run: nil, workflow: workflow, step: nil, error: message)
  end
end
