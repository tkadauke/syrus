module AgentMemory
  # The plugin's `memory_store` provider: everything core asks of a memory
  # store, in one place. Core never names `AgentMemory::Entry`; it asks
  # `Syrus::Memory`, which asks this.
  class Store
    include Syrus::Plugin::MemoryStore

    ORDER = Arel.sql(
      "CASE WHEN scope = 'repository' THEN 0 ELSE 1 END, " \
      "confidence IS NULL ASC, confidence DESC, " \
      "last_verified_at IS NULL ASC, last_verified_at DESC, created_at DESC"
    ).freeze

    def self.prompt_context(user:, repository_ids:)
      PromptContext.new(user: user, repository_ids: repository_ids).to_s
    end

    # Pinned-context lines for a chat system prompt, clipped to the caller's
    # remaining byte budget. The last line reports what was left out, so a
    # truncated list never reads as a complete one.
    def self.chat_context_lines(user:, repository_ids:, byte_budget:)
      return [] if user.blank?

      entries = Entry.visible_to(user, repository_ids).order(ORDER)
      remaining = byte_budget.to_i
      rendered = 0
      total = entries.size

      lines = entries.filter_map do |entry|
        next if remaining <= 0

        line = "#{label_for(entry)} #{entry.content.squish}"
        clipped = line.safe_byteslice(0, remaining)
        remaining -= clipped.bytesize
        rendered += 1
        "  - #{clipped}#{clipped.bytesize < line.bytesize ? "..." : ""}"
      end

      omitted = total - rendered
      lines << "  - (#{omitted} more not shown — call list_memories to retrieve them)" if omitted.positive?
      lines
    end

    def self.chat_instructions
      <<~TEXT.strip
        ## Memory

        Use the Syrus memory MCP tools to persist facts across conversations.
        Do NOT write to the filesystem for memory -- not to MEMORY.md, not to
        any chat workspace directory.

        **When to save:** user profile details (role, expertise), corrections
        and confirmed approaches, project decisions, external references,
        architectural choices.

        **Tools:**
        - `write_memory(kind, scope, content)` -- create a memory.
          `scope: global` for cross-repo facts; `scope: repository` +
          `scope_id` (repository id) for repo-specific ones.
        - `list_memories` / `search_memories(query)` -- retrieve. Call when
          prior context seems relevant.
        - `read_memory(memory_id)` -- read the full content of a specific
          memory.
        - `delete_memory(memory_id)` -- remove stale or wrong memories when
          asked.
        - `publish_memory(memory_id)` -- share with all users in that scope.
        - `unpublish_memory(memory_id)` -- make it private again.

        **Kinds:** `user_pref`, `feedback`, `project_fact`, `reference`, `decision`.
      TEXT
    end

    def self.label_for(entry)
      scope_suffix = entry.scope == "repository" ? "/#{entry.scope_id}" : ""
      "[#{entry.kind}#{scope_suffix}#{entry.published? ? "/shared" : ""}]"
    end
    private_class_method :label_for
  end
end
