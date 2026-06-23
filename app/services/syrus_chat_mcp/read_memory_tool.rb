require "mcp"

module SyrusChatMcp
  class ReadMemoryTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "read_memory"

    description "Read a memory owned by the current user or a published memory for an attached repository."

    input_schema(
      properties: {
        memory_id: { type: "integer", description: "Chat memory id." }
      },
      required: %w[memory_id]
    )

    class << self
      def call(memory_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        memory = readable_memory_for(chat_session, memory_id)
        return SyrusChatMcp.invalid("memory not found or not visible: #{memory_id}") unless memory

        SyrusChatMcp.success(memory: memory_payload(memory))
      end
    end
  end
end
