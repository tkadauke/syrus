module WorkUnits
  class Scheduler
    DEFAULT_GATES = [
      Gates::ManualPause
    ].freeze

    def self.evaluate!(work_unit, gates: DEFAULT_GATES)
      new(work_unit, gates: gates).evaluate!
    end

    def initialize(work_unit, gates:)
      @work_unit = work_unit
      @gates = gates
    end

    def evaluate!
      gates.each do |gate|
        result = gate.call(work_unit)
        next if result.pass?

        work_unit.block!(
          reason: result.reason,
          blocked_until: result.retry_at,
          details: result.details
        )
        return result
      end

      work_unit.unblock! if work_unit.blocked?
      GateResult.pass
    end

    private

    attr_reader :work_unit, :gates
  end
end
