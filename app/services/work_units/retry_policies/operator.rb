module WorkUnits
  module RetryPolicies
    class Operator
      def automatic? = false
      def continuation?(_step) = false
      def new_attempt?(_step) = true
    end
  end
end
