class BaseRefreshRetryEnqueuer
  Result = Data.define(:workflow, :checkpoint, :error) do
    def success? = workflow.present?
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
    return failure("The selected source workflow is not a failed workflow for this Job.") unless valid_source?(source)

    checkpoint = latest_published_mutation_checkpoint(source)
    return failure("No published mutation checkpoint is available for the selected failed workflow.") unless checkpoint

    base_ref = job.effective_base_branch.to_s.presence
    return failure("The Job has no effective base ref to refresh onto.") unless base_ref

    base_sha = RepositoryContent.for(effective_base_repository, user: job.user).resolve(base_ref, max_age: 0).id
    artifacts = provenance(source, checkpoint, base_ref, base_sha)
    workflow = WorkUnits::Launcher.instantiate(
      kind: "base_refresh_retry",
      job: job,
      artifacts: artifacts,
      agent_provider: agent_provider
    )
    WorkUnits::Launcher.start!(workflow)
    Result.new(workflow: workflow, checkpoint: checkpoint, error: nil)
  rescue WorkUnits::Launcher::LockConflict
    failure("Active mutation work must finish before starting a base refresh retry.")
  rescue RepositoryContent::Error => e
    failure("The current effective base could not be resolved: #{e.message}")
  end

  private

  attr_reader :job, :source_workflow, :reason, :agent_provider

  def selected_source_workflow
    source_workflow || job.workflows.where(state: "failed").order(created_at: :desc, id: :desc).first
  end

  def valid_source?(source)
    source&.job_id == job.id && source.failed?
  end

  def latest_published_mutation_checkpoint(source)
    RunCheckpoint.published
      .where(workflow_id: source.id)
      .recent
      .first
  end

  def effective_base_repository
    job.base_on_upstream_default? ? job.base_repository : job.repository
  end

  def provenance(source, checkpoint, base_ref, base_sha)
    source_snapshot = WorkflowSourceSnapshots.current_for(source)
    {
      "checkpoint_ref" => checkpoint.remote_ref,
      "checkpoint_sha" => checkpoint.commit_sha,
      "checkpoint_source_run_id" => checkpoint.run_id,
      "checkpoint_source_workflow_id" => source.id,
      "base_refresh_source_snapshot_id" => source_snapshot&.id,
      "base_refresh_source_snapshot_ref" => source_snapshot&.source_ref,
      "base_refresh_source_snapshot_sha" => source_snapshot&.source_sha,
      "base_refresh_old_base_ref" => source.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT).presence || job.mergeability_base_ref.presence || base_ref,
      "base_refresh_old_base_sha" => checkpoint.base_sha.presence || source.artifact(RebaseTarget::BASE_SHA_ARTIFACT).presence || job.mergeability_base_sha,
      RebaseTarget::BASE_BRANCH_ARTIFACT => base_ref,
      RebaseTarget::BASE_SHA_ARTIFACT => base_sha,
      "base_refresh_reason" => reason
    }.compact
  end

  def failure(message)
    Result.new(workflow: nil, checkpoint: nil, error: message)
  end
end
