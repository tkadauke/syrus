module Steps
  # Compatibility shim for workflows that materialized the retired core
  # review_plan step before the feature was removed. New workflows no longer
  # create this step, and the submit_review_plan MCP tool/comment formatter are
  # intentionally gone.
  class ReviewPlan < Base
    def call
      log("[review_plan] retired legacy PR-comment step - skipping")
      step.update!(
        details: step.details.to_h.merge(
          "skipped" => true,
          "skip_reason" => "review_plan_retired"
        )
      )
    end
  end
end
