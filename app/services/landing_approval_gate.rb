class LandingApprovalGate
  # Re-verify approval at landing time because repository access, recorded
  # approvals, or the configured delivery policy may have changed after the
  # Job entered :approved. Auto-rule approvals carry their intent in
  # approved_via/approval_evidence rather than JobApproval rows.
  def self.satisfied?(job, policy: nil)
    return true if job.approved_via_auto_rule?
    policy ||= DeliveryPolicy.for(repository: job.repository)
    return policy.job_approval_satisfied?(job) if policy.approval_configured?
    return true unless job.job_approvals.exists?

    job.approval_satisfied?
  end
end
