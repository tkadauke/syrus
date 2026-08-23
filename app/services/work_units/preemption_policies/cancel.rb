module WorkUnits
  module PreemptionPolicies
    class Cancel
      def mode = :cancel
      def checkpoint? = false
      def resume_strategy = :new_attempt
    end
  end
end
