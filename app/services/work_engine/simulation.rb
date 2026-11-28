module WorkEngine
  module Simulation
    DEFAULT_MAX_TICKS = 200

    # `invariant_violations` lists the unexpected invariant violations that
    # ended the scenario (status "violated"); `final_states` maps each Job's
    # slug to its state when the scenario ended, so the fuzzer can judge
    # whether a quiescent world is explicably settled.
    Result = Data.define(:scenario, :ticks, :status, :events, :stuck_reasons, :wait_reasons, :job_ids, :epic_ids, :work_intent_ids, :invariant_violations, :final_states) do
      def initialize(invariant_violations: [], final_states: {}, **attrs)
        super(invariant_violations: invariant_violations, final_states: final_states, **attrs)
      end

      def success? = status == "success"
      def waiting? = status == "waiting"
      def stuck? = status == "stuck"
      def error? = status == "error"
      def violated? = status == "violated"
    end

    Outcome = Data.define(:default, :steps)
  end
end
