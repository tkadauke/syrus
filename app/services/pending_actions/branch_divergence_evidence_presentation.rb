module PendingActions
  # Shared presentation_detail for the branch-divergence recovery actions
  # (AdoptCurrentPrHead, ReplacePrBranchWithWorkflowOutput,
  # RetryFromCurrentPrBranch): all three render the same recorded
  # branch_divergence evidence snapshot.
  module BranchDivergenceEvidencePresentation
    def presentation_detail
      evidence = payload["evidence"].to_h
      [
        "Remote SHA: #{evidence["remote_sha"].presence || "unknown"}",
        "Workflow local SHA: #{evidence["workflow_local_sha"].presence || "unknown"}",
        "Base SHA: #{evidence["base_sha"].presence || "unknown"}",
        Array(evidence.dig("diff_summary", "files")).presence&.then { |files| "Changed files: #{files.first(10).join(", ")}" }
      ].compact.join("\n")
    end
  end
end
