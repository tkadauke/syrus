require "mcp"

module SyrusChatMcp
  class SearchMemoriesTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "search_memories"

    description "Search visible chat memories by content."

    input_schema(
      properties: {
        query: { type: "string", description: "Content query." },
        scope: { type: "string", enum: ChatMemory::SCOPE, description: "Optional scope filter." },
        kind: { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
        limit: { type: "integer", description: "Maximum results, default 10, max 50." }
      },
      required: %w[query]
    )

    class << self
      def call(query:, server_context:, scope: nil, kind: nil, limit: nil)
        chat_session = server_context.fetch(:chat_session)
        query = query.to_s.strip
        return SyrusChatMcp.invalid("query is required") if query.empty?

        memories = apply_memory_filters(visible_memories_for(chat_session), requested_scope: scope.to_s.presence, kind: kind.to_s.presence)
        return memories if memories.is_a?(MCP::Tool::Response)

        normalized_query = query.downcase
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query)}%"
        memories = memories
          .where("LOWER(chat_memories.content) LIKE ? AND INSTR(LOWER(chat_memories.content), ?) > 0", pattern, normalized_query)
          .order(Arel.sql("INSTR(LOWER(chat_memories.content), #{ActiveRecord::Base.connection.quote(normalized_query)}) ASC"), updated_at: :desc, id: :desc)
          .limit(normalized_limit(limit, default: 10, max: 50))

        SyrusChatMcp.success(memories: memories.map { |memory| memory_payload(memory) })
      end
    end
  end
end
