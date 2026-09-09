module WorkflowSourceSnapshots
  InfrastructureStateError = Class.new(StandardError)

  module_function

  def record!(workflow:, source_sha:, source_ref:, creator_step:, tree_sha: nil, fingerprint: nil, published_at: Time.current)
    workflow.source_snapshots.create!(
      source_sha: source_sha,
      source_ref: source_ref,
      tree_sha: tree_sha,
      fingerprint: fingerprint,
      creator_step: creator_step,
      published_at: published_at
    )
  end

  def current_for(workflow)
    workflow.source_snapshots.published.newest_first.first
  end

  def require_current!(workflow, source_sha: nil, source_ref: nil, tree_sha: nil, fingerprint: nil)
    snapshot = current_for(workflow)
    raise InfrastructureStateError, "workflow source snapshot metadata missing" unless snapshot

    mismatches = []
    mismatches << "source_sha" if source_sha.present? && snapshot.source_sha != source_sha
    mismatches << "source_ref" if source_ref.present? && snapshot.source_ref != source_ref
    mismatches << "tree_sha" if tree_sha.present? && snapshot.tree_sha != tree_sha
    mismatches << "fingerprint" if fingerprint.present? && snapshot.fingerprint != fingerprint

    if mismatches.any?
      raise InfrastructureStateError, "workflow source snapshot metadata mismatch: #{mismatches.join(', ')}"
    end

    snapshot
  end
end
