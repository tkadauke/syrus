module WorkUnits
  module PreemptionPolicies
    class None
      def mode = :none
      def checkpoint? = false
      def resume_strategy = :none
    end
  end
end
