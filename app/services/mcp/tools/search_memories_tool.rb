require "mcp"

module Mcp
  module Tools
    class SearchMemoriesTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "search_memories"

      description "Search active memories by content. In workflow runs, searches " \
                  "only within the job's repository. In chat sessions, searches " \
                  "all visible memories across global and attached repositories."

      input_schema(
        properties: {
          query: { type: "string", description: "Content query." },
          scope: { type: "string", enum: ChatMemory::TOOL_SCOPES, description: "Optional scope filter (chat sessions only; ignored in workflow runs)." },
          kind:  { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
          limit: { type: "integer", description: "Maximum results, default 10, max 50." }
        },
        required: %w[query]
      )

      class << self
        def call(query:, server_context:, scope: nil, kind: nil, limit: nil)
          context = McpToolContext.from_server_context(server_context)
          query   = query.to_s.strip
          return invalid_response("query is required") if query.empty?

          memories = visible_memories_for(context)

          if scope.present?
            requested = scope.to_s
            if context.allowed_memory_scopes.include?(requested)
              memories = memories.where(scope: requested)
            else
              return invalid_response("scope must be one of #{context.allowed_memory_scopes.join(', ')}")
            end
          end

          if kind.present?
            return invalid_response("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind.to_s)
            memories = memories.where(kind: kind.to_s)
          end

          normalized_query = query.downcase
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query)}%"
          memories = memories
            .where("LOWER(chat_memories.content) LIKE ? AND INSTR(LOWER(chat_memories.content), ?) > 0", pattern, normalized_query)
            .order(Arel.sql("INSTR(LOWER(chat_memories.content), #{ActiveRecord::Base.connection.quote(normalized_query)}) ASC"), updated_at: :desc, id: :desc)
            .limit(normalized_limit(limit, default: 10, max: 50))

          success_response(memories: memories.map { |m| memory_payload(m) })
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::SearchMemoriesTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end
      end
    end
  end
end
