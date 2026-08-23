module WorkIntents
  module Gates
    class PolicyEligibility
      REASON = "policy_not_eligible"

      def self.call(intent) = new(intent).call

      def initialize(intent)
        @intent = intent
      end

      def call
        return GateResult.pass if intent.definition.generic_intent_start_allowed?

        GateResult.wait(
          reason: REASON,
          details: {
            "policy" => "domain_dispatcher_required",
            "kind" => intent.kind
          }
        )
      end

      private

      attr_reader :intent
    end
  end
end
