module WorkUnits
  module Gates
    class ManualPause
      def self.call(work_unit) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless work_unit.pause_requested?

        GateResult.block(
          reason: "manual_pause",
          details: { "pause_requested" => true }
        )
      end

      private

      attr_reader :work_unit
    end
  end
end
