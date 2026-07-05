class RetryFailedStepEnqueuer
  Result = Data.define(:run, :workflow, :step, :error) do
    def success? = run.present?
  end

  def self.call(...) = new(...).call
  def self.failed_step_for(workflow)
    workflow.steps.where(state: "failed").reorder(position: :desc, id: :desc).first
  end

  def initialize(workflow:, parent_session_id: nil, prompt: nil, agent_provider: nil)
    @workflow = workflow
    @parent_session_id = parent_session_id
    @prompt = prompt
    @agent_provider = agent_provider.to_s.presence
  end

  def call
    return failure("Workflow is not in a failed state.") unless workflow.failed?
    return failure("Workspace already cleaned up - use Start over.") unless workflow.retry_available?

    failed_step = self.class.failed_step_for(workflow)
    return failure("No failed step to retry.") unless failed_step
    return rebuild_merge_train if failed_step.kind == "merge_train_land"

    workflow.reopen!
    workflow.save!
    failed_step.reopen!
    failed_step.save!

    if workflow.landing_workflow?
      job = workflow.job
      job.update_columns(landing_failure_reason: nil) if job.landing_failure_reason.present?
    end

    run = failed_step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: agent_provider || workflow.agent_provider,
      parent_session_id: parent_session_id,
      prompt: prompt
    )

    Result.new(run: run, workflow: workflow, step: failed_step, error: nil)
  end

  private

  attr_reader :workflow, :parent_session_id, :prompt, :agent_provider

  def rebuild_merge_train
    train_id = workflow.artifact("merge_train_id")
    train = MergeTrain.find_by(id: train_id)
    return failure("Merge train not found; use Start over.") unless train

    rebuilt_workflow = MergeTrainDispatcher.try_dispatch!(train.epic)
    unless rebuilt_workflow
      reason = MergeTrainDispatcher.blocker_reason(train.epic).presence ||
        "merge-train dispatch was blocked by a concurrent state change"
      return failure("Epic is not ready for a merge-train rebuild: #{reason}.")
    end

    run = rebuilt_workflow.runs.order(:created_at).last
    return failure("Merge-train rebuild did not enqueue a run.") unless run

    Result.new(run: run, workflow: rebuilt_workflow, step: run.step, error: nil)
  end

  def failure(message)
    Result.new(run: nil, workflow: workflow, step: nil, error: message)
  end
end
