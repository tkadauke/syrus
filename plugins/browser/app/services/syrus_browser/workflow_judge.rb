module SyrusBrowser
  class WorkflowJudge
    TRIGGER_KINDS = %w[initial retry pr_comment chat_feedback coding_handoff].freeze

    def self.judges
      [
        {
          step_kind: "visual_review",
          order: 20,
          trigger_kinds: TRIGGER_KINDS,
          rounds_for: ->(job) {
            plan = SyrusBrowser::RepoVisualReviewPlan.for_job(job)
            plan.enabled? ? plan.rounds : 0
          }
        }
      ]
    end
  end
end
