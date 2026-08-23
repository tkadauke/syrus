module WorkUnits
  module RetryPolicies
    class ResumeStepOrNewWorkflow
      def automatic? = true

      def continuation?(step)
        return false unless step

        Step::Kind.fetch(step.kind)
        true
      rescue ArgumentError
        false
      end

      def new_attempt?(step)
        !continuation?(step)
      end

      def rebuild_unit?(_step) = false
    end
  end
end
