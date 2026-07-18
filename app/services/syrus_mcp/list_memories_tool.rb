require "mcp"

module SyrusMcp
  class ListMemoriesTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "list_memories"

    description "List active memories within the current Job's repository."

    input_schema(
      properties: {
        kind: { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
        limit: { type: "integer", description: "Maximum results, default 20, max 100." }
      }
    )

    class << self
      def call(server_context:, kind: nil, limit: nil)
        run = SyrusMcp.run_from_context(server_context)

        memories = repository_memories_for(run)

        if kind.present?
          return SyrusMcp.invalid("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind.to_s)
          memories = memories.where(kind: kind.to_s)
        end

        memories = memories
          .order(updated_at: :desc, id: :desc)
          .limit(normalized_limit(limit, default: 20, max: 100))

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate({ memories: memories.map { |m| memory_payload(m) } }) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ListMemoriesTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
