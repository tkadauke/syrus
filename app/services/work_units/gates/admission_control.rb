module WorkUnits
  module Gates
    class AdmissionControl
      REASON = "admission_control"
      RESOURCE_SAFETY_REASON = "resource_safety"

      def self.call(work_unit) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless workflow

        decision = ::WorkflowAdmissionBudget.call(workflow: workflow)
        return GateResult.pass if decision.admit?

        GateResult.block(
          reason: blocked_reason(decision),
          retry_at: decision.delay_until || StepDispatcher::START_BLOCKED_BACKOFF.from_now,
          details: decision.artifact
        )
      end

      private

      attr_reader :work_unit

      def workflow
        work_unit.workflow
      end

      def blocked_reason(decision)
        StepDispatcher.hard_resource_pause?(decision) ? RESOURCE_SAFETY_REASON : REASON
      end
    end
  end
end
