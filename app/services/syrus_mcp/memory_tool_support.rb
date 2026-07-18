module SyrusMcp
  module MemoryToolSupport
    private

    def memory_payload(memory)
      {
        id: memory.id,
        kind: memory.kind,
        scope: memory.scope,
        scope_id: memory.scope_id,
        content: memory.content,
        source_type: memory.source_type,
        source_id: memory.source_id,
        author: memory.author,
        confidence: memory.confidence,
        last_verified_at: memory.last_verified_at&.iso8601,
        expires_at: memory.expires_at&.iso8601,
        visibility: memory.visibility,
        created_at: memory.created_at.iso8601
      }
    end

    def repository_memories_for(run)
      ChatMemory.active
                .where(scope: "repository", scope_id: run.job.repository_id)
                .where("chat_memories.user_id = ? OR chat_memories.published = ?", run.job.user_id, true)
    end

    def normalized_limit(value, default:, max:)
      limit = Integer(value.presence || default, exception: false)
      return default unless limit

      limit.clamp(1, max)
    end
  end
end
