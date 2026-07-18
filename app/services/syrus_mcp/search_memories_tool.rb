require "mcp"

module SyrusMcp
  class SearchMemoriesTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "search_memories"

    description "Search active memories within the current Job's repository by content."

    input_schema(
      properties: {
        query: { type: "string", description: "Content query." },
        kind: { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
        limit: { type: "integer", description: "Maximum results, default 10, max 50." }
      },
      required: %w[query]
    )

    class << self
      def call(query:, server_context:, kind: nil, limit: nil)
        run = SyrusMcp.run_from_context(server_context)
        query = query.to_s.strip
        return SyrusMcp.invalid("query is required") if query.empty?

        memories = repository_memories_for(run)

        if kind.present?
          return SyrusMcp.invalid("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind.to_s)
          memories = memories.where(kind: kind.to_s)
        end

        normalized_query = query.downcase
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query)}%"
        memories = memories
          .where("LOWER(chat_memories.content) LIKE ? AND INSTR(LOWER(chat_memories.content), ?) > 0", pattern, normalized_query)
          .order(Arel.sql("INSTR(LOWER(chat_memories.content), #{ActiveRecord::Base.connection.quote(normalized_query)}) ASC"), updated_at: :desc, id: :desc)
          .limit(normalized_limit(limit, default: 10, max: 50))

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate({ memories: memories.map { |m| memory_payload(m) } }) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SearchMemoriesTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
