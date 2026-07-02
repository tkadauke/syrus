require "mcp"

module SyrusMcp
  class ReadMemoryTool < MCP::Tool
    tool_name "read_memory"

    description "Read the full content of a ChatMemory owned by the current Job's user."

    input_schema(
      properties: {
        id: { type: "integer", description: "Chat memory id." }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        run = SyrusMcp.run_from_context(server_context)
        memory = ChatMemory.find_by!(id: id, user_id: run.job.user_id)

        payload = {
          kind: memory.kind,
          scope: memory.scope,
          content: memory.content,
          created_at: memory.created_at.iso8601
        }

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue ActiveRecord::RecordNotFound
        invalid("memory not found: #{id}")
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadMemoryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end
    end
  end
end
