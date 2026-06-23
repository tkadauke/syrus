require "mcp"

module SyrusChatMcp
  class ListMemoriesTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "list_memories"

    description "List memories visible in this chat session."

    input_schema(
      properties: {
        scope: { type: "string", enum: ChatMemory::SCOPE, description: "Optional scope filter." },
        kind: { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
        limit: { type: "integer", description: "Maximum results, default 20, max 100." }
      }
    )

    class << self
      def call(server_context:, scope: nil, kind: nil, limit: nil)
        chat_session = server_context.fetch(:chat_session)
        memories = apply_memory_filters(visible_memories_for(chat_session), requested_scope: scope.to_s.presence, kind: kind.to_s.presence)
        return memories if memories.is_a?(MCP::Tool::Response)

        memories = memories.order(updated_at: :desc, id: :desc).limit(normalized_limit(limit, default: 20, max: 100))

        SyrusChatMcp.success(memories: memories.map { |memory| memory_payload(memory) })
      end
    end
  end
end
