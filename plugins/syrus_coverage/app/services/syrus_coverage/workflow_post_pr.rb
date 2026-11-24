module SyrusCoverage
  # Contributes the PR comment to `workflow:post_pr`: the pull request has to
  # exist before it can be commented on, and a comment that fails to post is
  # advisory, so it must never fail the workflow (`fail_policy: :advance`).
  class WorkflowPostPr
    def self.post_pr
      [
        {
          step_kind: "coverage_pr_comment",
          order: 10,
          fail_policy: :advance,
          enabled_for: ->(job) { SyrusCoverage::PlanReader.for_job(job).present? }
        }
      ]
    end
  end
end
