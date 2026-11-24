module WorkUnits
  module Gates
    # Blocks a WorkUnit start while any enabled work_gate provider vetoes the
    # workflow. Core does not know which plugin vetoes or why: a provider may
    # name the WorkUnit block reason through `details["block_reason"]`, and the
    # veto's own reason is the fallback.
    class WorkGateVeto
      def self.call(work_unit, **) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless workflow

        veto = StepDispatcher.work_gate_veto(workflow)
        return GateResult.pass unless veto

        details = veto.details.to_h.stringify_keys
        reason = details.delete("block_reason").presence || veto.reason
        GateResult.block(
          reason: reason,
          retry_at: StepDispatcher::START_BLOCKED_BACKOFF.from_now,
          details: details
        )
      end

      private

      attr_reader :work_unit

      def workflow
        work_unit.workflow
      end
    end
  end
end
