require "mcp"

module Mcp
  module Tools
    class ListMemoriesTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "list_memories"

      description "List active memories. In workflow runs, lists only memories " \
                  "within the job's repository. In chat sessions, lists all " \
                  "visible memories across global and attached repositories."

      input_schema(
        properties: {
          scope: { type: "string", enum: ChatMemory::TOOL_SCOPES, description: "Optional scope filter (chat sessions only; ignored in workflow runs)." },
          kind:  { type: "string", enum: ChatMemory::KIND, description: "Optional kind filter." },
          limit: { type: "integer", description: "Maximum results, default 20, max 100." }
        }
      )

      class << self
        def call(server_context:, scope: nil, kind: nil, limit: nil)
          context = McpToolContext.from_server_context(server_context)

          memories = visible_memories_for(context)

          if scope.present?
            requested = scope.to_s
            if context.allowed_memory_scopes.include?(requested)
              memories = memories.where(scope: requested)
            else
              return invalid_response("scope must be one of #{context.allowed_memory_scopes.join(', ')}")
            end
          end

          if kind.present?
            return invalid_response("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind.to_s)
            memories = memories.where(kind: kind.to_s)
          end

          memories = memories
            .order(updated_at: :desc, id: :desc)
            .limit(normalized_limit(limit, default: 20, max: 100))

          success_response(memories: memories.map { |m| memory_payload(m) })
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::ListMemoriesTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end
      end
    end
  end
end
