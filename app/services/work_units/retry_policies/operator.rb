module WorkUnits
  module RetryPolicies
    class Operator
      def automatic? = false
      def continuation?(_step) = false
      def new_attempt?(_step) = true
      def rebuild_unit?(_step) = false
    end
  end
end
