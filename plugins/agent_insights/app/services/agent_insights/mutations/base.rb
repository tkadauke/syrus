module AgentInsights
  module Mutations
    class Base
      MAX_BATCH_SIZE = 50

      Result = Struct.new(:ok?, :message, :suggestions, :jobs, :memories, :failures, keyword_init: true)

      def self.validate_ids(id:, ids:, singular_name: "insight_id")
        return [ nil, "provide only one of #{singular_name} or insight_ids" ] if id.present? && !ids.nil?
        return [ nil, "provide one of #{singular_name} or insight_ids" ] if id.blank? && ids.nil?

        values = ids.nil? ? [ id ] : Array(ids)
        normalized = values.filter_map { |value| Integer(value, exception: false) }
        return [ nil, "insight_ids must be an array of integers" ] if normalized.size != values.size

        normalized.uniq!
        return [ nil, "insight_ids must not be empty" ] if normalized.empty?
        return [ nil, "insight_ids cannot contain more than #{MAX_BATCH_SIZE} ids" ] if normalized.size > MAX_BATCH_SIZE

        [ normalized, nil ]
      end

      def initialize(ids:, actor:, repository_scope:)
        @ids = ids
        @actor = actor
        @repository_scope = repository_scope
      end

      def validate
        suggestions, failures = load_targets
        failures.concat(suggestions.filter_map { |suggestion| validation_failure(suggestion) })
        Result.new(ok?: failures.empty?, suggestions: suggestions, failures: failures, message: failures.join("; "))
      end

      def apply!
        result = nil
        ApplicationRecord.transaction do
          suggestions = AgentInsights::Suggestion.where(id: ids).order(:id).lock.to_a
          failures = target_failures(suggestions)
          failures.concat(suggestions.filter_map { |suggestion| validation_failure(suggestion) })
          raise ArgumentError, failures.join("; ") if failures.any?

          result = perform(suggestions)
        end
        result
      end

      private

      attr_reader :ids, :actor, :repository_scope

      def load_targets
        suggestions = AgentInsights::Suggestion.where(id: ids).order(:id).to_a
        [ suggestions, target_failures(suggestions) ]
      end

      def target_failures(suggestions)
        found = suggestions.index_by(&:id)
        visible_ids = repository_scope.where(id: suggestions.map(&:repository_id)).pluck(:id).to_set
        ids.filter_map do |id|
          suggestion = found[id]
          if suggestion.nil? || !visible_ids.include?(suggestion.repository_id)
            "target_insight_id must reference an accessible insight (##{id})"
          end
        end
      end

      def validation_failure(_suggestion)
        raise NotImplementedError
      end

      def perform(_suggestions)
        raise NotImplementedError
      end
    end
  end
end
