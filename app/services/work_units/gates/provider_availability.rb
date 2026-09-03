module WorkUnits
  module Gates
    class ProviderAvailability
      REASON = "provider_availability"

      def self.call(work_unit, **context) = new(work_unit, **context).call

      def initialize(work_unit, step: nil)
        @work_unit = work_unit
        @step = step
      end

      def call
        return GateResult.pass unless workflow

        decision = ::ProviderAvailabilityPause.call(workflow: workflow)
        apply_failover!(decision) if decision.failover?
        return GateResult.pass unless decision.pause?

        GateResult.block(
          reason: REASON,
          retry_at: decision.retry_at,
          details: details_for(decision)
        )
      end

      private

      attr_reader :work_unit, :step

      def workflow
        work_unit.workflow
      end

      def details_for(decision)
        return decision.details unless step

        decision.details.merge(
          "phase_step_id" => step.id,
          "phase_step_kind" => step.kind,
          "phase_step_position" => step.position
        )
      end

      def apply_failover!(decision)
        workflow.with_lock do
          workflow.reload
          return if workflow.runs.exists?
          return if workflow.agent_provider == decision.failover.selected_provider

          workflow.update!(
            agent_provider: decision.failover.selected_provider,
            artifacts: workflow.artifacts.to_h.merge("provider_failover_decision" => decision.failover.artifact)
          )
        end
      end
    end
  end
end
