require "mcp"

module SyrusChatMcp
  class DeleteMemoryTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "delete_memory"

    description "Mark a memory owned by the current user as deleted."

    input_schema(
      properties: {
        memory_id: { type: "integer", description: "Chat memory id." }
      },
      required: %w[memory_id]
    )

    class << self
      def call(memory_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        memory = owned_memory_for(chat_session, memory_id)
        return SyrusChatMcp.invalid("memory not found or not owned: #{memory_id}") unless memory

        memory.soft_delete_by!(chat_session.user)
        SyrusChatMcp.success(id: memory.id, deleted: true)
      end
    end
  end
end
