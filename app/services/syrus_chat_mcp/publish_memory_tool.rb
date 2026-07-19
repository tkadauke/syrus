require "mcp"

module SyrusChatMcp
  class PublishMemoryTool < MCP::Tool
    extend Mcp::Tools::MemoryToolSupport

    tool_name "publish_memory"

    description "Publish a repository-scoped memory owned by the current user."

    input_schema(
      properties: {
        memory_id: { type: "integer", description: "Chat memory id." }
      },
      required: %w[memory_id]
    )

    class << self
      def call(memory_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        id = Integer(memory_id, exception: false)
        memory = id && ChatMemory.active.find_by(id: id, user_id: chat_session.user_id)
        return SyrusChatMcp.invalid("memory not found or not owned: #{memory_id}") unless memory
        return SyrusChatMcp.invalid("global memories cannot be published") if memory.global?

        memory.update!(published: true)
        SyrusChatMcp.success(memory: memory_payload(memory))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
