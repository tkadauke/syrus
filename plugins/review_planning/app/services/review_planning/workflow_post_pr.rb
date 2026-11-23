module ReviewPlanning
  # Contributes the self-review step to `workflow:post_pr`: the pull request has
  # to exist before it can be commented on, and the step is best-effort, so it
  # must never fail the workflow (`fail_policy: :advance`).
  class WorkflowPostPr
    def self.post_pr
      [
        {
          step_kind: "review_plan",
          order: 20,
          fail_policy: :advance,
          enabled_for: ->(job) { ReviewPlanning::Plan.for_job(job).enabled? }
        }
      ]
    end
  end
end
