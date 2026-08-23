module WorkUnits
  module Gates
    class ManualPause
      REASON = "manual_pause"

      def self.call(work_unit, **context) = new(work_unit, **context).call

      def initialize(work_unit, step: nil)
        @work_unit = work_unit
        @step = step
      end

      def call
        return GateResult.pass unless work_unit.pause_requested?

        GateResult.block(
          reason: REASON,
          details: details
        )
      end

      private

      attr_reader :work_unit, :step

      def details
        payload = { "pause_requested" => true }
        return payload unless step

        payload.merge(
          "phase_step_id" => step.id,
          "phase_step_kind" => step.kind,
          "phase_step_position" => step.position
        )
      end
    end
  end
end
