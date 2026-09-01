module Steps
  # Aggregates the results of the preflight grader steps in a
  # MainBranchRepair workflow. Three outcomes:
  #
  # - All required preflight graders passed: sets the "preflight_passed"
  #   workflow artifact, skips all downstream steps (implement, the grade
  #   loop, summarize, etc.), and returns. The dispatcher then walks past the
  #   skipped steps and marks the workflow succeeded.
  #   Workflows::MainBranchRepair#after_success detects the artifact and
  #   marks the repository healthy without the agent ever running.
  #
  # - Any required preflight grader failed for a non-timeout reason: logs the
  #   failures and returns normally so the chain continues to implement →
  #   grade loop.
  #
  # - Required preflight grader failures are timeout-like only: records an
  #   inconclusive preflight artifact and skips the repair chain. Timeout-only
  #   grader output is not actionable implementation feedback unless the
  #   repository explicitly opts into treating grader timeouts as failures.
  #
  # Unlike GraderCollect this step never raises StepFailed — it is not
  # inside a retry_until loop and a grader failure here means "proceed to
  # implement", not "fail the workflow".
  class PreflightGraderCollect < Base
    def call
      preflight_steps = preflight_grader_steps

      failed_required = preflight_steps.select do |g|
        g.details && g.details["required"] && g.state == "failed"
      end

      if failed_required.empty?
        log("[preflight_grader_collect] all required graders passed (#{preflight_steps.size} grader step(s)) — skipping implement")
        workflow.set_artifact!("preflight_passed", true)
        cancel_downstream!(reason: "preflight graders passed — main is already healthy")
      elsif timeout_only?(failed_required)
        failed_names = failed_required.map { |g| g.details["name"] }.join(", ")
        log("[preflight_grader_collect] preflight graders timed out: #{failed_names} — marking main health inconclusive")
        workflow.set_artifact!("preflight_inconclusive", true)
        workflow.set_artifact!(
          "preflight_inconclusive_failed_names",
          failed_required.map { |g| g.details["name"].presence || "unnamed" }
        )
        cancel_downstream!(reason: "preflight graders timed out — main repair needs operator review")
      else
        failed_names = failed_required.map { |g| g.details["name"] }.join(", ")
        log("[preflight_grader_collect] preflight graders failed: #{failed_names} — proceeding to implement")
      end
    end

    private

    def preflight_grader_steps
      workflow.steps.where(kind: "preflight_grader").order(:position).to_a
    end

    def timeout_only?(failed_required)
      return false if repository.treat_grader_timeouts_as_failures?

      failed_required.all? { |grader_step| GraderFailureSignal.timeout_like_step?(grader_step) }
    end
  end
end
