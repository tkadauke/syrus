require "mcp"

module SyrusMcp
  class DeleteMemoryTool < MCP::Tool
    tool_name "delete_memory"

    description "Soft-delete an active memory owned by the current Job's user and scoped to the Job's repository."

    input_schema(
      properties: {
        memory_id: { type: "integer", description: "Chat memory id to delete." }
      },
      required: %w[memory_id]
    )

    class << self
      def call(memory_id:, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        memory = ChatMemory.active.find_by(
          id: memory_id,
          user_id: run.job.user_id,
          scope: "repository",
          scope_id: run.job.repository_id
        )

        unless memory
          return MCP::Tool::Response.new(
            [ { type: "text", text: "Error: memory not found or not accessible: #{memory_id}" } ],
            error: true
          )
        end

        memory.soft_delete_by!(run)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate({ id: memory.id, deleted: true }) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::DeleteMemoryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
