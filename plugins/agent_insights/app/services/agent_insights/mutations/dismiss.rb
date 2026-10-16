module AgentInsights
  module Mutations
    class Dismiss < Base
      def initialize(reason:, **kwargs)
        super(**kwargs)
        @reason = CommandRedactor.redact(Mcp::Tools.utf8(reason)).strip
      end

      attr_reader :reason

      def validation_failure(suggestion)
        return "reason is required" if reason.blank?
        "Insight ##{suggestion.id} must be pending" unless suggestion.pending?
      end

      def perform(suggestions)
        suggestions.each { |suggestion| suggestion.dismiss!(reason: reason, actor: audit_actor) || raise(ArgumentError, "Insight ##{suggestion.id} changed concurrently") }
        Result.new(ok?: true, message: "Dismissed #{suggestions.size} #{'insight'.pluralize(suggestions.size)}.", suggestions: suggestions.map(&:reload), jobs: [], memories: [], failures: [])
      end

      private
    end
  end
end
