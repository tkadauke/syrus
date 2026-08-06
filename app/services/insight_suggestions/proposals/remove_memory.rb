module InsightSuggestions
  module Proposals
    class RemoveMemory < Base
      def accept!(actor:, params: {})
        memory = deletable_memory_for(actor)
        return accept_already_removed_memory if target_memory_already_removed?
        return Result.error("Target memory not found or not accessible.") unless memory

        ActiveRecord::Base.transaction do
          memory.soft_delete_by!(actor)
          result = Base.accept_suggestion!(suggestion)
          raise ActiveRecord::Rollback unless result.ok?

          return Result.ok(
            message: "Memory removed and suggestion accepted.",
            suggestion: result.suggestion,
            memory: memory.reload
          )
        end
      end

      private

      def accept_already_removed_memory
        if suggestion.accept_obsolete_remove_memory! || suggestion.accepted?
          return Result.ok(
            message: "Memory was already removed and suggestion accepted.",
            suggestion: suggestion.reload,
            memory: suggestion.target_memory
          )
        end

        Result.error("Suggestion cannot be accepted (already dismissed).")
      end

      def target_memory_already_removed?
        memory = suggestion.target_memory
        memory.nil? || memory.deleted?
      end

      def deletable_memory_for(actor)
        scope = ChatMemory.active.where(id: suggestion.target_memory_id)
        return scope.first if actor.admin?

        scope.find_by(
          user_id: actor.id,
          scope: "repository",
          scope_id: suggestion.repository_id
        )
      end
    end
  end
end
