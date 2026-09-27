module OperatorBriefing
  class ReviewFinding < ApplicationRecord
    self.table_name = "operator_briefing_review_findings"

    REVIEW_KINDS = %w[adversarial visual].freeze
    VERDICTS = %w[needs_work approved skipped].freeze

    belongs_to :workflow, class_name: "::Workflow"
    belongs_to :step, class_name: "::Step", optional: true
    belongs_to :run, class_name: "::Run", optional: true

    validates :review_kind, presence: true, inclusion: { in: REVIEW_KINDS }
    validates :verdict, presence: true, inclusion: { in: VERDICTS }
    validates :iteration, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :critique, presence: true

    scope :overridden, -> { where(overridden: true) }

    def self.record!(workflow:, review_kind:, iteration:, verdict:, critique:, step: nil, run: nil, artifacts: [], skipped: false, skip_reason: nil)
      transaction do
        finding = find_or_initialize_by(
          workflow: workflow,
          review_kind: review_kind,
          iteration: iteration,
          run_id: run&.id
        )
        finding.assign_attributes(
          step: step,
          run: run,
          verdict: verdict,
          critique: critique,
          artifacts: artifacts || [],
          skipped: skipped,
          skip_reason: skip_reason
        )
        finding.save!
        mark_prior_findings_overridden!(workflow: workflow, review_kind: review_kind) if verdict != "needs_work"
        finding
      end
    end

    def self.mark_prior_findings_overridden!(workflow:, review_kind:)
      where(workflow: workflow, review_kind: review_kind, verdict: "needs_work", overridden: false)
        .update_all(overridden: true, overridden_at: Time.current, updated_at: Time.current)
    end
  end
end
