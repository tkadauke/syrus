module InsightSuggestions
  module Proposals
    class Base
      TYPES = {
        "create_job" => "InsightSuggestions::Proposals::CreateJob",
        "save_memory" => "InsightSuggestions::Proposals::SaveMemory",
        "remove_memory" => "InsightSuggestions::Proposals::RemoveMemory",
        "revise_existing_insight" => "InsightSuggestions::Proposals::Informational",
        "informational" => "InsightSuggestions::Proposals::Informational"
      }.freeze

      def self.for(suggestion)
        TYPES.fetch(suggestion.effective_proposal_type).constantize.new(suggestion)
      end

      def initialize(suggestion)
        @suggestion = suggestion
      end

      def accept!(actor:, params: {})
        raise NotImplementedError
      end

      def self.accept_suggestion!(suggestion, created_job: nil)
        unless suggestion.accept!(created_job: created_job)
          return Result.error("Suggestion cannot be accepted (already accepted or dismissed).")
        end

        Result.ok(suggestion: suggestion.reload, job: created_job)
      end

      Result = Struct.new(:ok?, :message, :suggestion, :job, :memory, keyword_init: true) do
        def self.ok(message: "Suggestion accepted.", suggestion:, job: nil, memory: nil)
          new(ok?: true, message: message, suggestion: suggestion, job: job, memory: memory)
        end

        def self.error(message)
          new(ok?: false, message: message)
        end
      end

      private

      attr_reader :suggestion
    end
  end
end
