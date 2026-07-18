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
        memory = ChatMemory.find_by(id: id, user_id: run.job.user_id, deleted_at: nil)

        unless memory
          return MCP::Tool::Response.new(
            [ { type: "text", text: "Error: memory not found or not accessible: #{id}" } ],
            error: true
          )
        end

        payload = {
          id: memory.id,
          kind: memory.kind,
          scope: memory.scope,
          scope_id: memory.scope_id,
          content: memory.content,
          source_type: memory.source_type,
          source_id: memory.source_id,
          author: memory.author,
          confidence: memory.confidence,
          last_verified_at: memory.last_verified_at&.iso8601,
          expires_at: memory.expires_at&.iso8601,
          visibility: memory.visibility,
          created_at: memory.created_at.iso8601
        }

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadMemoryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
