module ReviewEvidence::Capture
  PROMPT_VERSION = "1".freeze
  TOOL_POLICY_VERSION = "1".freeze
  PROVIDER_DEFAULT_MODEL = "provider-default".freeze

  module_function

  def call(run:, workspace_path:, review_kind:, base_ref:, checklist: [])
    base_sha = ReviewEvidence::CanonicalDiff.resolve(workspace_path: workspace_path, ref: base_ref)
    snapshot = ReviewEvidence::CanonicalDiff.snapshot(workspace_path: workspace_path, base_sha: base_sha)

    ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: review_kind,
      provider: run.agent_provider,
      model: run.model.presence || PROVIDER_DEFAULT_MODEL,
      reviewed_base_sha: base_sha,
      reviewed_head_sha: snapshot.fetch(:head_sha),
      canonical_diff_sha256: snapshot.fetch(:sha256),
      prompt_version: PROMPT_VERSION,
      checklist_version: Digest::SHA256.hexdigest(JSON.generate(Array(checklist).map(&:to_s))),
      tool_policy_version: TOOL_POLICY_VERSION
    )
  end
end
