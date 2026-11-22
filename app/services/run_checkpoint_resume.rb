class RunCheckpointResume
  SAFE_FAILED_STEP_KINDS = %w[
    summarize
    test_plan
    pr_open
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
    if RetryFailedStepEnqueuer.crosses_uncleared_retry_until_barrier?(failed_step)
      return failure("Workflow has an uncleared retry-until failure before #{failed_step.kind}.")
    end

    checkpoint = checkpoint_before(failed_step)
    return failure("No published mutation checkpoint is available before #{failed_step.kind}.") unless checkpoint

    workflow = WorkUnits::Launcher.instantiate(
      kind: "checkpoint_resume",
      job: job,
      agent_provider: agent_provider,
      artifacts: checkpoint_artifacts(source, failed_step, checkpoint)
    )
    Result.new(workflow: workflow, checkpoint: checkpoint, error: nil)
  rescue WorkUnits::Launcher::LockConflict
    failure("a workflow is already queued or running for this job")
  end

  private

  attr_reader :job, :agent_provider, :artifacts

  # The attempt being retried is the Job's newest one. Only it may be resumed:
  # an older failed attempt's checkpoint predates whatever ran since (a
  # feedback workflow that pushed, a later failure elsewhere), so resuming it
  # would restore and push superseded code. Child workflows (landing
  # validation, visual diffs) are not attempts and do not count
  # (formal/SyrusModel/CheckpointLineage.lean).
  def source_workflow
    workflow = job.workflows
                  .where(trigger_kind: Workflow::TriggerKind.runtime_role_values("first_class"))
                  .reorder(created_at: :desc, id: :desc)
                  .first
    return nil unless workflow&.failed?

    failed_step = RetryFailedStepEnqueuer.failed_step_for(workflow)
    return nil unless failed_step &&
      safe_failed_step?(failed_step) &&
      !RetryFailedStepEnqueuer.crosses_uncleared_retry_until_barrier?(failed_step) &&
      checkpoint_before(failed_step).present?

    workflow
  end

  def safe_failed_step?(step)
    SAFE_FAILED_STEP_KINDS.include?(step.kind)
  end

  def checkpoint_before(step)
    step_ids = step.workflow.steps.where("position < ?", step.position).select(:id)
    RunCheckpoint.published
                 .where(workflow_id: step.workflow_id, step_id: step_ids)
                 .order(created_at: :desc, id: :desc)
                 .first || inherited_checkpoint(step.workflow)
  end

  # A checkpoint-resume attempt restores the checkpoint it resumed from and
  # replays only the steps after it, so it publishes no checkpoint of its own.
  # When it fails, that inherited checkpoint is still the right basis -- every
  # step it ran is one it will run again. Without this, its retry fell back to
  # a fresh implementation and discarded the completed work.
  def inherited_checkpoint(workflow)
    return nil unless workflow.artifact("checkpoint_resume")

    run_id = workflow.artifact("checkpoint_source_run_id")
    sha = workflow.artifact("checkpoint_sha").to_s
    return nil if run_id.blank? || sha.blank?

    RunCheckpoint.published
                 .where(run_id: run_id, commit_sha: sha)
                 .order(created_at: :desc, id: :desc)
                 .first
  end

  def checkpoint_artifacts(source, failed_step, checkpoint)
    WorkflowArtifactSanitizer.without_branch_divergence(source.artifacts)
      .merge(WorkflowArtifactSanitizer.without_branch_divergence(artifacts))
      .merge(
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
