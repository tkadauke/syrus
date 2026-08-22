class RunCheckpointResume
  SAFE_FAILED_STEP_KINDS = %w[
    summarize
    test_plan
    pr_open
    review_plan
    coverage_analyze
    coverage_pr_comment
    summarize_amend
    refresh_job_metadata
    push
  ].freeze

  Result = Data.define(:workflow, :checkpoint, :error) do
    def success? = workflow.present?
  end

  def self.call(...) = new(...).call

  def initialize(job:, agent_provider: nil, artifacts: nil)
    @job = job
    @agent_provider = agent_provider.to_s.presence
    @artifacts = artifacts.to_h
  end

  def call
    source = source_workflow
    return failure("No failed workflow is available for checkpoint resume.") unless source

    failed_step = RetryFailedStepEnqueuer.failed_step_for(source)
    return failure("No failed step is available for checkpoint resume.") unless failed_step
    return failure("Step #{failed_step.kind} is not safe to resume from a checkpoint.") unless safe_failed_step?(failed_step)

    checkpoint = checkpoint_before(failed_step)
    return failure("No published mutation checkpoint is available before #{failed_step.kind}.") unless checkpoint

    workflow = WorkUnits::Launcher.instantiate(
      kind: "checkpoint_resume",
      job: job,
      agent_provider: agent_provider,
      artifacts: checkpoint_artifacts(source, failed_step, checkpoint)
    )
    Result.new(workflow: workflow, checkpoint: checkpoint, error: nil)
  end

  private

  attr_reader :job, :agent_provider, :artifacts

  def source_workflow
    job.workflows
       .where(state: "failed")
       .where.not(cleaned_up_at: nil)
       .order(created_at: :desc, id: :desc)
       .first
  end

  def safe_failed_step?(step)
    SAFE_FAILED_STEP_KINDS.include?(step.kind)
  end

  def checkpoint_before(step)
    step_ids = step.workflow.steps.where("position < ?", step.position).select(:id)
    RunCheckpoint.published
                 .where(workflow_id: step.workflow_id, step_id: step_ids)
                 .order(created_at: :desc, id: :desc)
                 .first
  end

  def checkpoint_artifacts(source, failed_step, checkpoint)
    source.artifacts.to_h.merge(artifacts).merge(
      "checkpoint_resume" => true,
      "checkpoint_ref" => checkpoint.remote_ref,
      "checkpoint_sha" => checkpoint.commit_sha,
      "checkpoint_source_run_id" => checkpoint.run_id,
      "checkpoint_source_workflow_id" => source.id,
      "checkpoint_resume_from_step_id" => failed_step.id,
      "checkpoint_resume_from_step_kind" => failed_step.kind,
      "checkpoint_resume_steps" => resume_steps(failed_step)
    )
  end

  def resume_steps(failed_step)
    kinds = failed_step.workflow.steps
                       .where("position >= ?", failed_step.position)
                       .order(:position, :id)
                       .pluck(:kind)
    return kinds if kinds.first == "prepare"

    [ "prepare", *kinds ]
  end

  def failure(message)
    Result.new(workflow: nil, checkpoint: nil, error: message)
  end
end
