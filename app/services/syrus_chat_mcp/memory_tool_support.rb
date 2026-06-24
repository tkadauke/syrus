module SyrusChatMcp
  module MemoryToolSupport
    private

    def memory_payload(memory)
      {
        id: memory.id,
        content: memory.content,
        kind: memory.kind,
        scope: memory.scope,
        scope_id: memory.scope_id,
        published: memory.published?,
        user_id: memory.user_id,
        deleted_at: memory.deleted_at&.iso8601,
        deleted_by_user_id: memory.deleted_by_user_id,
        created_at: memory.created_at.iso8601,
        updated_at: memory.updated_at.iso8601
      }
    end

    def visible_memories_for(chat_session)
      user_id = chat_session.user_id
      repository_ids = attached_repository_ids(chat_session)

      own_global = ChatMemory.active.where(user_id: user_id, scope: "global", scope_id: nil)
      return own_global if repository_ids.empty?

      ChatMemory.active.where(
        <<~SQL.squish,
          (
            chat_memories.user_id = :user_id
            AND (
              (chat_memories.scope = 'global' AND chat_memories.scope_id IS NULL)
              OR (chat_memories.scope = 'repository' AND chat_memories.scope_id IN (:repository_ids))
            )
          )
          OR (
            chat_memories.user_id != :user_id
            AND chat_memories.scope = 'repository'
            AND chat_memories.scope_id IN (:repository_ids)
            AND chat_memories.published = :published
          )
        SQL
        user_id: user_id,
        repository_ids: repository_ids,
        published: true
      )
    end

    def readable_memory_for(chat_session, memory_id)
      id = Integer(memory_id, exception: false)
      return unless id

      memory = ChatMemory.active.find_by(id: id)
      return unless memory
      return memory if memory.user_id == chat_session.user_id
      return memory if memory.repository? && memory.published? && attached_repository_ids(chat_session).include?(memory.scope_id)
    end

    def owned_memory_for(chat_session, memory_id)
      id = Integer(memory_id, exception: false)
      return unless id

      ChatMemory.active.where(user_id: chat_session.user_id).find_by(id: id)
    end

    def owned_repository_for(chat_session, scope_id)
      repository_id = Integer(scope_id, exception: false)
      return unless repository_id

      chat_session.user.repositories.find_by(id: repository_id)
    end

    def apply_memory_filters(scope, requested_scope:, kind:)
      if requested_scope.present?
        return SyrusChatMcp.invalid("scope must be global or repository") unless ChatMemory::SCOPE.include?(requested_scope)

        scope = scope.where(scope: requested_scope)
      end

      if kind.present?
        return SyrusChatMcp.invalid("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind)

        scope = scope.where(kind: kind)
      end

      scope
    end

    def normalized_limit(value, default:, max:)
      limit = Integer(value.presence || default, exception: false)
      return default unless limit

      limit.clamp(1, max)
    end

    def attached_repository_ids(chat_session)
      chat_session.attached_repositories.ids
    end
  end
end
