module ReviewEvidence::Capture
  PROMPT_VERSION = "1".freeze
  TOOL_POLICY_VERSION = "1".freeze
  module_function

  def call(run:, workspace_path:, review_kind:, base_ref:, checklist: [])
    provider = AgentProviders.for(run.agent_provider)
    model = provider.resolve_model(run.model.presence || run.workflow.model.presence)
    raise ArgumentError, "reviewer model must be resolved before evidence capture" if model.blank?

    run.update!(model: model) if run.model.blank?
    base_sha = ReviewEvidence::CanonicalDiff.resolve(workspace_path: workspace_path, ref: base_ref)
    diff_snapshot = ReviewEvidence::CanonicalDiff.snapshot(workspace_path: workspace_path, base_sha: base_sha)

    target = run.step.details.to_h["reviewer_target"]&.deep_stringify_keys
    target_snapshot = target&.then do |payload|
      ReviewerTargets.snapshot(payload, owner: run.job.owner_user || run.job.user, repository: run.job.repository)
    end
    ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: review_kind,
      provider: run.agent_provider,
      model: run.model,
      target_envelope: target,
      target_snapshot: target_snapshot,
      reviewed_base_sha: base_sha,
      reviewed_head_sha: diff_snapshot.fetch(:head_sha),
      canonical_diff_sha256: diff_snapshot.fetch(:sha256),
      prompt_version: PROMPT_VERSION,
      checklist_version: Digest::SHA256.hexdigest(JSON.generate(Array(checklist).map(&:to_s))),
      tool_policy_version: TOOL_POLICY_VERSION
    )
  end
end
