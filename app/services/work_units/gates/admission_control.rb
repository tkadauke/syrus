module WorkUnits
  module Gates
    class AdmissionControl
      REASON = "admission_control"
      RESOURCE_SAFETY_REASON = "resource_safety"

      def self.call(work_unit, **context) = new(work_unit, **context).call

      def initialize(work_unit, step: nil)
        @work_unit = work_unit
        @step = step
      end

      def call
        return GateResult.pass unless workflow

        decision = if step
          ::WorkflowAdmissionBudget.call(workflow: workflow, step: step)
        else
          ::WorkflowAdmissionBudget.call(workflow: workflow)
        end
        return GateResult.pass if decision.admit?
        return GateResult.pass if step && StepDispatcher.whole_workflow_policy_ignores_phase_delay?(decision)

        GateResult.block(
          reason: blocked_reason(decision),
          retry_at: decision.delay_until || StepDispatcher::START_BLOCKED_BACKOFF.from_now,
          details: details_for(decision)
        )
      end

      private

      attr_reader :work_unit, :step

      def workflow
        work_unit.workflow
      end

      def blocked_reason(decision)
        StepDispatcher.hard_resource_pause?(decision) ? RESOURCE_SAFETY_REASON : REASON
      end

      def details_for(decision)
        return decision.artifact unless step

        decision.artifact.merge(
          "phase_step_id" => step.id,
          "phase_step_kind" => step.kind,
          "phase_step_position" => step.position
        )
      end
    end
  end
end
