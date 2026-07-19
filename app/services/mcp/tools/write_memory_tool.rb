require "mcp"

module Mcp
  module Tools
    class WriteMemoryTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "write_memory"

      description "Write a persistent memory. In chat sessions the scope can be " \
                  "'global' (personal) or 'repository' (tied to a repository). " \
                  "In workflow runs the scope is always 'repository' and is set " \
                  "automatically; author, source_type, and source_id are derived " \
                  "from the agent run context."

      input_schema(
        properties: {
          content:  { type: "string", description: "Memory content (max #{ChatMemory::CONTENT_MAX_LENGTH} characters)." },
          kind:     { type: "string", enum: ChatMemory::KIND, description: "Memory kind." },
          scope:    { type: "string", enum: ChatMemory::TOOL_SCOPES, description: "Memory scope: global or repository. Omit to default to repository in workflow runs." },
          scope_id: { type: "integer", description: "Repository id when scope is 'repository'. Required in chat sessions; inferred from run context in workflow runs." }
        },
        required: %w[content kind]
      )

      class << self
        def call(content:, kind:, server_context:, scope: nil, scope_id: nil)
          context = McpToolContext.from_server_context(server_context)
          content = content.to_s.strip
          kind    = kind.to_s

          return invalid_response("content is required") if content.empty?
          return invalid_response("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind)

          effective_scope = resolve_scope(context, scope)
          return effective_scope if effective_scope.is_a?(MCP::Tool::Response)

          repository = nil
          if effective_scope == "repository"
            repository = resolve_repository(context, scope_id)
            return repository if repository.is_a?(MCP::Tool::Response)
          elsif scope_id.present?
            return invalid_response("scope_id must be omitted for global memories")
          end

          author, source_type, source_id = run_provenance(context)

          memory = ChatMemory.create!(
            user:        context.user,
            content:     content,
            kind:        kind,
            scope:       effective_scope,
            scope_id:    repository&.id,
            author:      author,
            source_type: source_type,
            source_id:   source_id
          )

          success_response(id: memory.id, memory: memory_payload(memory))
        rescue ActiveRecord::RecordInvalid => e
          invalid_response(e.record.errors.full_messages.to_sentence)
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::WriteMemoryTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def resolve_scope(context, requested_scope)
          if requested_scope.present?
            scope = requested_scope.to_s
            unless context.allowed_memory_scopes.include?(scope)
              return invalid_response("scope must be one of #{context.allowed_memory_scopes.join(', ')}")
            end

            scope
          else
            context.allowed_memory_scopes.first
          end
        end

        def resolve_repository(context, scope_id)
          if context.run?
            context.repository
          else
            repo = writable_repository_for(context, scope_id)
            repo || invalid_response("scope_id must be a repository id owned by the current user")
          end
        end

        def run_provenance(context)
          if context.run?
            [ "agent", "run", context.run.id ]
          else
            [ nil, nil, nil ]
          end
        end
      end
    end
  end
end
