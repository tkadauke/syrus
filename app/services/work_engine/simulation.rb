module WorkEngine
  module Simulation
    DEFAULT_MAX_TICKS = 200

    Result = Data.define(:scenario, :ticks, :status, :events, :stuck_reasons, :wait_reasons, :job_ids, :epic_ids, :work_intent_ids) do
      def success? = status == "success"
      def waiting? = status == "waiting"
      def stuck? = status == "stuck"
    end

    Outcome = Data.define(:default, :steps)
  end
end
