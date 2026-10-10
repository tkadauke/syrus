module WorkflowArtifactSanitizer
  BRANCH_DIVERGENCE_KEYS = %w[
    branch_divergence
    branch_divergence_recovery
    branch_divergence_recovery_error
    branch_divergence_recovery_pending
  ].freeze

  def self.without_branch_divergence(artifacts)
    artifacts.to_h.except(*BRANCH_DIVERGENCE_KEYS)
  end
end
