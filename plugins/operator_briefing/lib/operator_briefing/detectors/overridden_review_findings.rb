module OperatorBriefing
  module Detectors
    class OverriddenReviewFindings < Base
      def self.detector_key = "review_findings"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        return [] unless defined?(OperatorBriefing::ReviewFinding)

        overridden = OperatorBriefing::ReviewFinding
          .where(workflow: workflow, verdict: "needs_work")
          .where(overridden: true)
          .order(:review_kind, :iteration, :id)
          .limit(20)
        return [] if overridden.empty?

        [ fact(
          key: "overridden_review_findings",
          severity: "attention_debt",
          summary: "Adversarial or visual review findings were overridden.",
          evidence: overridden.map { |finding|
            {
              "review_finding_id" => finding.id,
              "review_kind" => finding.review_kind,
              "iteration" => finding.iteration,
              "verdict" => finding.verdict
            }
          }
        ) ]
      end
    end
  end
end
