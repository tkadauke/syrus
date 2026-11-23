module ReviewPlanning
  # Compatibility handler for workflows that materialized the retired
  # review_plan step before the feature was removed. It never runs an agent and
  # never fails: it records the skip and lets the workflow advance.
  class LegacyStep < Steps::Base
    SKIP_REASON = "review_plan_retired".freeze

    def call
      log("[review_plan] retired legacy PR-comment step - skipping")
      step.update!(
        details: step.details.to_h.merge("skipped" => true, "skip_reason" => SKIP_REASON)
      )
    end
  end
end
