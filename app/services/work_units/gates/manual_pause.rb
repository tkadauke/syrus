module WorkUnits
  module Gates
    class ManualPause
      REASON = "manual_pause"

      def self.call(work_unit) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless work_unit.pause_requested?

        GateResult.block(
          reason: REASON,
          details: { "pause_requested" => true }
        )
      end

      private

      attr_reader :work_unit
    end
  end
end
