module WorkUnits
  module PreemptionPolicies
    class Rebuild
      def mode = :rebuild
      def checkpoint? = false
      def resume_strategy = :rebuild_unit
    end
  end
end
