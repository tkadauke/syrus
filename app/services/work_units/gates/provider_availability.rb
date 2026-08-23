module WorkUnits
  module Gates
    class ProviderAvailability
      REASON = "provider_availability"

      def self.call(work_unit) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless workflow

        decision = ::ProviderAvailabilityPause.call(workflow: workflow)
        return GateResult.pass unless decision.pause?

        GateResult.block(
          reason: REASON,
          retry_at: decision.retry_at,
          details: decision.details
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
