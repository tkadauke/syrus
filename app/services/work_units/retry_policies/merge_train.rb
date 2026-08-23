module WorkUnits
  module RetryPolicies
    class MergeTrain
      def automatic? = true

      def continuation?(step)
        return false unless step

        Step::Kind.fetch(step.kind).repair_semantics == :agentic
      rescue ArgumentError
        false
      end

      def new_attempt?(step)
        rebuild_unit?(step)
      end

      def rebuild_unit?(step)
        return true unless step

        !continuation?(step)
      end
    end
  end
end
