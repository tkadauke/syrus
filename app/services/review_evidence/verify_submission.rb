module ReviewEvidence::VerifySubmission
  class Mismatch < StandardError
    attr_reader :code, :details

    def initialize(code, details)
      @code = code
      @details = details
      super(code.humanize)
    end
  end

  module_function

  def call!(evidence:, workspace_path:)
    raise Mismatch.new("review_evidence_stale", evidence.terminal_failure_details.to_h) if evidence.stale?

    snapshot = ReviewEvidence::CanonicalDiff.snapshot(
      workspace_path: workspace_path,
      base_sha: evidence.reviewed_base_sha
    )
    mismatches = {}
    if snapshot.fetch(:head_sha) != evidence.reviewed_head_sha
      mismatches[:reviewed_head_sha] = evidence.reviewed_head_sha
      mismatches[:current_head_sha] = snapshot.fetch(:head_sha)
    end
    if snapshot.fetch(:sha256) != evidence.canonical_diff_sha256
      mismatches[:reviewed_diff_sha256] = evidence.canonical_diff_sha256
      mismatches[:current_diff_sha256] = snapshot.fetch(:sha256)
    end
    return evidence if mismatches.empty?

    evidence.mark_stale!(code: "review_evidence_mismatch", details: mismatches)
    raise Mismatch.new("review_evidence_mismatch", mismatches)
  rescue Mismatch
    raise
  rescue StandardError => e
    details = { error_class: e.class.name, message: e.message }
    evidence.mark_failed!(code: "review_evidence_verification_failed", details: details)
    raise Mismatch.new("review_evidence_verification_failed", details)
  end
end
