class BaseRefreshRetryEnqueuer
  Result = Data.define(:workflow, :checkpoint, :error, :launch_result) do
    def success? = workflow.present? && error.blank?
  end

  def self.call(...) = new(...).call

  def initialize(job:, source_workflow: nil, reason:, agent_provider: nil)
    @job = job
    @source_workflow = source_workflow
    @reason = reason.to_s.strip
    @agent_provider = agent_provider.to_s.presence
  end

  def call
    return failure("A reason is required for a base refresh retry.") if reason.blank?

    source = selected_source_workflow
    return failure("The selected source workflow is not a failed workflow for this Job.") unless source&.job_id == job.id && source.failed?

    checkpoint = latest_checkpoint(source)
    return failure("No published mutation checkpoint is available for the selected failed workflow.") unless checkpoint

    base_ref = job.effective_base_branch.to_s.presence
    return failure("The Job has no effective base ref to refresh onto.") unless base_ref

    base_sha = RepositoryContent.for(effective_base_repository, user: job.user).resolve(base_ref, max_age: 0).id
    workflow = instantiate_retry!(source, checkpoint, base_ref, base_sha)
    workflow.set_artifact!(RebaseTarget::BRANCH_ARTIFACT, WorkflowWorkspace.new(workflow).branch_name)
    launch = WorkUnits::Launcher.start!(workflow)
    if launch.not_started?
      return Result.new(workflow: workflow, checkpoint: checkpoint,
                        error: "Base refresh retry did not start: #{launch.reason || 'unknown start block'}", launch_result: launch)
    end

    Result.new(workflow: workflow, checkpoint: checkpoint, error: nil, launch_result: launch)
  rescue WorkUnits::Launcher::LockConflict
    failure("Active mutation work must finish before starting a base refresh retry.")
  rescue RepositoryContent::Error => e
    failure("The current effective base could not be resolved: #{e.message}")
  rescue ArgumentError => e
    failure(e.message)
  end

  private

  attr_reader :job, :source_workflow, :reason, :agent_provider

  def selected_source_workflow
    source_workflow || job.workflows.where(state: "failed").order(created_at: :desc, id: :desc).first
  end

  def latest_checkpoint(source)
    RunCheckpoint.published.where(workflow_id: source.id).recent.first
  end

  def effective_base_repository
    job.base_on_upstream_default? ? job.base_repository : job.repository
  end

  def instantiate_retry!(source, checkpoint, base_ref, base_sha)
    job.with_lock do
      job.reload
      eligibility = RetryWorkflowEligibility.call(job: job)
      raise ArgumentError, eligibility.message unless eligibility.eligible?
      raise ArgumentError, "Job is not ready to retry after failure." unless job.may_retry_after_failure?

      job.retry_after_failure!
      job.save!
      WorkUnits::Launcher.instantiate(
        kind: "base_refresh_retry", job: job, agent_provider: agent_provider,
        artifacts: provenance(source, checkpoint, base_ref, base_sha)
      )
    end
  end

  def provenance(source, checkpoint, base_ref, base_sha)
    snapshot = WorkflowSourceSnapshots.current_for(source)
    {
      "checkpoint_ref" => checkpoint.remote_ref, "checkpoint_sha" => checkpoint.commit_sha,
      "checkpoint_source_run_id" => checkpoint.run_id, "checkpoint_source_workflow_id" => source.id,
      "base_refresh_source_snapshot_id" => snapshot&.id, "base_refresh_source_snapshot_ref" => snapshot&.source_ref,
      "base_refresh_source_snapshot_sha" => snapshot&.source_sha,
      "base_refresh_old_base_ref" => source.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT).presence || job.mergeability_base_ref.presence || base_ref,
      "base_refresh_old_base_sha" => checkpoint.base_sha.presence || source.artifact(RebaseTarget::BASE_SHA_ARTIFACT).presence || job.mergeability_base_sha,
      RebaseTarget::BASE_BRANCH_ARTIFACT => base_ref, RebaseTarget::BASE_SHA_ARTIFACT => base_sha,
      "base_refresh_reason" => reason
    }.compact
  end

  def failure(message)
    Result.new(workflow: nil, checkpoint: nil, error: message, launch_result: nil)
  end
end
