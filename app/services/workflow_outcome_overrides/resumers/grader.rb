module WorkflowOutcomeOverrides
  module Resumers
    class Grader
      def self.call(override)
        workflow = override.workflow
        return unless workflow.failed?

        step = override.step
        barrier = workflow.steps.find_by(
          kind: Step::Kind.fetch(step.kind).outcome_override_collector_kind,
          loop_id: step.loop_id, iteration: step.iteration, state: "failed"
        )
        return unless barrier

        result = RetryFailedStepEnqueuer.call(
          workflow:, failed_step: barrier, restart_grade_loop: false
        )
        raise Resumer::ResumeFailed, result.error unless result.success?

        result
      end
    end
  end
end
