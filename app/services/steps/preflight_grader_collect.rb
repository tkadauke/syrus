module Steps
  # Aggregates the results of the preflight grader steps in a
  # MainBranchRepair workflow. Two outcomes:
  #
  # - All required preflight graders passed: sets the "preflight_passed"
  #   workflow artifact, cancels all downstream steps (prepare, implement,
  #   the grade loop, summarize, etc.), and returns. The dispatcher then
  #   walks past the cancelled steps and marks the workflow succeeded.
  #   Workflows::MainBranchRepair#after_success detects the artifact and
  #   marks the repository healthy without the agent ever running.
  #
  # - Any required preflight grader failed: logs the failures and returns
  #   normally so the chain continues to prepare → implement → grade loop.
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
      else
        failed_names = failed_required.map { |g| g.details["name"] }.join(", ")
        log("[preflight_grader_collect] preflight graders failed: #{failed_names} — proceeding to implement")
      end
    end

    private

    def preflight_grader_steps
      workflow.steps.where(kind: "preflight_grader").order(:position).to_a
    end
  end
end
