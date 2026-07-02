module Prompts
  class MemoryContext
    FULL_CONTENT_KINDS = %w[feedback user_pref].freeze
    COMPACT_INDEX_KINDS = %w[project_fact decision reference].freeze
    COMPACT_CONTENT_BYTES = 120

    def initialize(user:, repository_ids:)
      @user = user
      @repository_ids = Array(repository_ids).compact
    end

    def to_s
      return "" unless @user

      memories = ChatMemory.visible_to(@user, @repository_ids).order(:created_at, :id).to_a
      return "" if memories.empty?

      [
        full_content_section(memories),
        compact_index_section(memories)
      ].compact_blank.join("\n\n")
    end

    private

    def full_content_section(memories)
      memories.select { |memory| FULL_CONTENT_KINDS.include?(memory.kind) }
        .map { |memory| "# Memory: #{memory.kind} (#{memory.id})\n#{memory.content}" }
        .join("\n\n")
    end

    def compact_index_section(memories)
      lines = memories.select { |memory| COMPACT_INDEX_KINDS.include?(memory.kind) }
        .map { |memory| "- [#{memory.id}] #{memory.kind}: #{compact_content(memory)}" }

      return "" if lines.empty?

      [
        "# Saved context (call read_memory(id) for full content)",
        *lines
      ].join("\n")
    end

    def compact_content(memory)
      memory.content.to_s.squish.safe_byteslice(0, COMPACT_CONTENT_BYTES)
    end
  end
end
