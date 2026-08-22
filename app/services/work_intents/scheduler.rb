module WorkIntents
  class Scheduler
    def self.evaluate!(intent, gates: nil)
      new(intent, gates: gates).evaluate!
    end

    def initialize(intent, gates:)
      @intent = intent
      @gates = gates || intent.definition.intent_gates
    end

    def evaluate!
      gates.each do |gate|
        result = gate.call(intent)
        next if result.pass?

        intent.wait!(
          reason: result.reason,
          wait_until: result.retry_at,
          details: result.details
        )
        return result
      end

      intent.request! if intent.waiting? && managed_wait_reason?(intent.wait_reason)
      GateResult.pass
    end

    private

    attr_reader :intent, :gates

    def managed_wait_reason?(reason)
      managed_wait_reasons.include?(reason)
    end

    def managed_wait_reasons
      @managed_wait_reasons ||= gates.filter_map do |gate|
        gate.const_get(:REASON) if gate.const_defined?(:REASON, false)
      end
    end
  end
end
