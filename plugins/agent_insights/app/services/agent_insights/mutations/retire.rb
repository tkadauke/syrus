module AgentInsights
  module Mutations
    class Retire < Base
      def initialize(reason:, retire_accepted: false, superseded_by_insight_ids: {}, superseded_by_job_ids: {}, **kwargs)
        super(**kwargs)
        @reason = CommandRedactor.redact(Mcp::Tools.utf8(reason)).strip
        @retire_accepted = ActiveModel::Type::Boolean.new.cast(retire_accepted)
        @superseded_by_insight_ids = normalize_references(superseded_by_insight_ids)
        @superseded_by_job_ids = normalize_references(superseded_by_job_ids)
      end

      attr_reader :reason

      def validation_failure(suggestion)
        return "reason is required" if reason.blank?
        return "Insight ##{suggestion.id} is already retired" if suggestion.retired?
        return "Insight ##{suggestion.id} is accepted and cannot be retired without retire_accepted: true" if suggestion.accepted? && !retire_accepted

        superseding_insight = superseding_insight_for(suggestion)
        if reference_present?(superseded_by_insight_ids, suggestion) && superseding_insight&.id == suggestion.id
          return "superseded_by_insight_id cannot reference the insight being retired"
        end
        if reference_present?(superseded_by_insight_ids, suggestion) && (!superseding_insight || superseding_insight.repository_id != suggestion.repository_id)
          return "superseded_by_insight_id must reference an accessible insight in the current repository"
        end
        if reference_present?(superseded_by_job_ids, suggestion) && superseding_job_for(suggestion).nil?
          return "Insight ##{suggestion.id} has an invalid superseding Job"
        end
      end

      def perform(suggestions)
        suggestions.each do |suggestion|
          ok = suggestion.retire!(reason: reason, actor: audit_actor, superseded_by_insight: superseding_insight_for(suggestion), superseded_by_job: superseding_job_for(suggestion), retire_accepted: retire_accepted)
          raise ArgumentError, "Insight ##{suggestion.id} changed concurrently" unless ok
        end
        Result.new(ok?: true, message: "Retired #{suggestions.size} #{'insight'.pluralize(suggestions.size)}.", suggestions: suggestions.map(&:reload), jobs: [], memories: [], failures: [])
      end

      private

      attr_reader :retire_accepted, :superseded_by_insight_ids, :superseded_by_job_ids

      def normalize_references(value)
        value.to_h.transform_keys(&:to_s)
      end

      def reference_present?(references, suggestion)
        references.key?(suggestion.id.to_s)
      end

      def superseding_insight_for(suggestion)
        id = Integer(superseded_by_insight_ids[suggestion.id.to_s], exception: false)
        id && AgentInsights::Suggestion.find_by(id: id)
      end

      def superseding_job_for(suggestion)
        id = Integer(superseded_by_job_ids[suggestion.id.to_s], exception: false)
        id && Job.find_by(id: id, repository_id: suggestion.repository_id)
      end
    end
  end
end
