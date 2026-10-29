module AgentMemory
  module Tools
    module MemoryToolSupport
      private

      def memory_payload(memory)
        {
          id:                memory.id,
          kind:              memory.kind,
          scope:             memory.scope,
          scope_id:          memory.scope_id,
          content:           memory.content,
          published:         memory.published?,
          user_id:           memory.user_id,
          source_type:       memory.source_type,
          source_id:         memory.source_id,
          author:            memory.author,
          confidence:        memory.confidence,
          last_verified_at:  memory.last_verified_at&.iso8601,
          expires_at:        memory.expires_at&.iso8601,
          visibility:        memory.visibility,
          deleted_at:        memory.deleted_at&.iso8601,
          deleted_by_user_id: memory.deleted_by_user_id,
          created_at:        memory.created_at.iso8601,
          updated_at:        memory.updated_at.iso8601
        }
      end

      # Returns memories visible to the agent based on context surface:
      #   run  — own + published memories within the job's repository
      #   chat — own global + own/published repository memories for attached repos
      #   coworker chat — everything its owner can read across their repositories
      def visible_memories_for(context)
        if context.run?
          AgentMemory::Entry.active
                    .where(scope: "repository", scope_id: context.repository.id)
                    .where("agent_memory_entries.user_id = ? OR agent_memory_entries.published = ?", context.user.id, true)
        elsif context.role == AgentRole::COWORKER_CHAT
          owned = AgentMemory::Entry.active.where(user_id: context.user.id)
          published = AgentMemory::Entry.active.where.not(user_id: context.user.id)
                                         .where(scope: "repository", scope_id: memory_repository_ids(context), published: true)
          owned.or(published)
        else
          AgentMemory::Entry.active.visible_to(context.user, context.allowed_repository_ids)
        end
      end

      # Returns a single memory the agent may read: owned memories always;
      # published repository memories only on the chat surface.
      def readable_memory_for(context, id)
        id = Integer(id, exception: false)
        return unless id

        memory = AgentMemory::Entry.active.find_by(id: id)
        return unless memory
        return memory if memory.user_id == context.user.id

        if context.chat?
          return memory if memory.repository? &&
                           memory.published? &&
                           memory_repository_ids(context).include?(memory.scope_id)
        end

        nil
      end

      def memory_repository_ids(context)
        return context.allowed_repository_ids unless context.role == AgentRole::COWORKER_CHAT

        Repository.accessible_repository_ids_for(context.user).pluck(:id)
      end

      # Returns the repository to write to given a requested scope and scope_id.
      # For the run surface the repository is always the job's repository.
      def writable_repository_for(context, scope_id)
        if context.run?
          context.repository
        else
          repository_id = Integer(scope_id, exception: false)
          return unless repository_id

          context.user.repositories.find_by(id: repository_id)
        end
      end

      def normalized_limit(value, default:, max:)
        limit = Integer(value.presence || default, exception: false)
        return default unless limit

        limit.clamp(1, max)
      end

      def invalid_response(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end

      def success_response(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      end
    end
  end
end
