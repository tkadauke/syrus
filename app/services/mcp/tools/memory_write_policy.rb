module Mcp
  module Tools
    class MemoryWritePolicy
      REGISTRY = {
        "agent_rebase" => "Mcp::Tools::MemoryWritePolicy::RebaseConflict",
        "stack_agent_rebase" => "Mcp::Tools::MemoryWritePolicy::RebaseConflict"
      }.freeze

      def self.for(context)
        policy_class_name = REGISTRY.fetch(context.run&.step&.kind, Default.name)
        policy_class_name.constantize.new(context)
      end

      def initialize(context)
        @context = context
      end

      def rejection_for(_content) = nil

      class Default < MemoryWritePolicy
      end

      class RebaseConflict < MemoryWritePolicy
        def rejection_for(content)
          return nil unless retry_storm?
          return nil unless prescriptive_abort_guidance?(content)

          "write_memory rejected: rebase conflict abort guidance from an active retry storm " \
            "must not become durable memory. Record verified file-level facts instead, or leave " \
            "the abort rationale in the run summary."
        end

        private

        attr_reader :context

        def retry_storm?
          prior_failures = RebaseAttemptGuard.consecutive_failures(context.job)
          prior_failures >= RebaseAttemptGuard::MEMORY_WRITE_RETRY_STORM_THRESHOLD
        end

        def prescriptive_abort_guidance?(content)
          normalized = content.to_s.downcase
          prescriptive_abort_instruction?(normalized) && abort_or_intervention_claim?(normalized)
        end

        def prescriptive_abort_instruction?(content)
          content.match?(
            /
              future\ agents?|
              future\ runs?|
              next\ agents?|
              do\ not\ re-?diagnose|
              don't\ re-?diagnose|
              skip\ re-?diagnosis|
              always|must|should|just
            /x
          )
        end

        def abort_or_intervention_claim?(content)
          content.match?(/abort|unresolvable|not resolvable|cannot be resolved|operator intervention/)
        end
      end
    end
  end
end
