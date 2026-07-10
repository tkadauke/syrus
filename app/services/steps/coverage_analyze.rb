module Steps
  # Parses coverage artifacts produced by graders, computes thresholds,
  # and stores results as workflow artifacts. Behavior depends on the
  # coverage plan's on_miss setting:
  #   block    → raises StepFailed when thresholds are not met (workflow fails)
  #   warn     → always succeeds; injects warning into next agent iteration
  #   schedule → always succeeds; enqueues a follow-up direct Job
  #
  # Full implementation is delivered in a follow-up Epic job.
  class CoverageAnalyze < Base
    def call
      log("[coverage_analyze] coverage analysis not yet implemented; passing through", kind: "system")
    end
  end
end
