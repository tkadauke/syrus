require "mcp"

module Mcp
  module Tools
    class ReadMemoryTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "read_memory"

      description "Read the full content of a ChatMemory owned by the current user " \
                  "(or a published memory for an attached repository in a chat session)."

      input_schema(
        properties: {
          id: { type: "integer", description: "Chat memory id." }
        },
        required: %w[id]
      )

      class << self
        def call(id:, server_context:)
          context = McpToolContext.from_server_context(server_context)
          memory = readable_memory_for(context, id)

          unless memory
            return MCP::Tool::Response.new(
              [ { type: "text", text: "Error: memory not found or not accessible: #{id}" } ],
              error: true
            )
          end

          success_response(memory: memory_payload(memory))
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::ReadMemoryTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end
      end
    end
  end
end
