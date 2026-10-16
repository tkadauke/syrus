module AgentInsights
  module Mutations
    class Accept < Base
      def validation_failure(suggestion)
        return completed_validation_failure(suggestion) if suggestion.accepted?
        return "Insight ##{suggestion.id} must be pending" unless suggestion.pending?

        proposal = Proposals::Base.for(suggestion)
        proposal.validation_error(actor: actor, params: proposal.automatic_accept_params)&.then { |error| "Insight ##{suggestion.id}: #{error}" }
      end

      def perform(suggestions)
        jobs = []
        memories = []
        suggestions.each do |suggestion|
          if suggestion.accepted?
            proposal = Proposals::Base.for(suggestion)
            jobs << proposal.accepted_job if proposal.accepted_job
            memories << proposal.accepted_memory if proposal.accepted_memory
            next
          end

          proposal = Proposals::Base.for(suggestion)
          result = proposal.accept!(actor: actor, params: proposal.automatic_accept_params)
          raise ArgumentError, "Insight ##{suggestion.id}: #{result.message}" unless result.ok?

          jobs << result.job if result.job
          memories << result.memory if result.memory
        end
        Result.new(ok?: true, message: "Accepted #{suggestions.size} #{'insight'.pluralize(suggestions.size)}.", suggestions: suggestions.map(&:reload), jobs: jobs, memories: memories, failures: [])
      end

      private

      def completed_validation_failure(suggestion)
        error = Proposals::Base.for(suggestion).completed_acceptance_error
        "Insight ##{suggestion.id} #{error}" if error
      end
    end
  end
end
