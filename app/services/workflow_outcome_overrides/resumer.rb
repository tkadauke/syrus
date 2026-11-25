module WorkflowOutcomeOverrides
  # Re-evaluates a failed deterministic gate after its exact failure has been
  # authorized. The collector consumes the override through the same
  # GraderResult/ReviewVerdict integration used during ordinary execution.
  class Resumer
    class ResumeFailed < StandardError; end

    def self.call(...) = new(...).call

    def initialize(override:)
      @override = override
    end

    def call
      return unless workflow.failed?

      barrier = failed_barrier
      return unless barrier

      result = RetryFailedStepEnqueuer.call(
        workflow:, failed_step: barrier, restart_grade_loop: false
      )
      raise ResumeFailed, result.error unless result.success?

      result
    end

    private

    attr_reader :override

    def workflow = override.workflow
    def step = override.step

    def failed_barrier
      return step if step&.failed? && step.kind == "review_panel_collect"
      return unless step&.kind.in?(%w[grader preflight_grader])

      collect_kind = step.kind == "grader" ? "grader_collect" : "preflight_grader_collect"
      workflow.steps.find_by(
        kind: collect_kind, loop_id: step.loop_id, iteration: step.iteration, state: "failed"
      )
    end
  end
end
