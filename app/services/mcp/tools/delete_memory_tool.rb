require "mcp"

module Mcp
  module Tools
    class DeleteMemoryTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "delete_memory"

      description "Soft-delete an active memory. In workflow runs the memory must " \
                  "be owned by the current user and scoped to the job's repository. " \
                  "In chat sessions the memory must be owned by the current user."

      input_schema(
        properties: {
          id: { type: "integer", description: "Chat memory id to delete." }
        },
        required: %w[id]
      )

      class << self
        def call(id:, server_context:)
          context = McpToolContext.from_server_context(server_context)

          memory = find_deletable_memory(context, id)

          unless memory
            return MCP::Tool::Response.new(
              [ { type: "text", text: "Error: memory not found or not accessible: #{id}" } ],
              error: true
            )
          end

          actor = context.run? ? context.run : context.user
          memory.soft_delete_by!(actor)

          success_response(id: memory.id, deleted: true)
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::DeleteMemoryTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def find_deletable_memory(context, id)
          memory_id = Integer(id, exception: false)
          return unless memory_id

          if context.run?
            ChatMemory.active.find_by(
              id:       memory_id,
              user_id:  context.user.id,
              scope:    "repository",
              scope_id: context.repository.id
            )
          else
            ChatMemory.active.find_by(id: memory_id, user_id: context.user.id)
          end
        end
      end
    end
  end
end
