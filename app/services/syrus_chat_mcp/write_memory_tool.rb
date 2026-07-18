require "mcp"

module SyrusChatMcp
  class WriteMemoryTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "write_memory"

    description "Write a persistent chat memory owned by the current user."

    input_schema(
      properties: {
        content: { type: "string", description: "Memory content." },
        kind: { type: "string", enum: ChatMemory::KIND, description: "Memory kind." },
        scope: { type: "string", enum: ChatMemory::TOOL_SCOPES, description: "Memory scope: global or repository." },
        scope_id: { type: "integer", description: "Repository id when scope is repository." }
      },
      required: %w[content kind scope]
    )

    class << self
      def call(content:, kind:, scope:, server_context:, scope_id: nil)
        chat_session = server_context.fetch(:chat_session)
        content = content.to_s.strip
        kind = kind.to_s
        scope = scope.to_s

        return SyrusChatMcp.invalid("content is required") if content.empty?
        return SyrusChatMcp.invalid("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind)
        return SyrusChatMcp.invalid("scope must be global or repository") unless ChatMemory::TOOL_SCOPES.include?(scope)

        repository = nil
        if scope == "repository"
          repository = owned_repository_for(chat_session, scope_id)
          return SyrusChatMcp.invalid("scope_id must be a repository id owned by the current user") unless repository
        elsif scope_id.present?
          return SyrusChatMcp.invalid("scope_id must be omitted for global memories")
        end

        memory = ChatMemory.create!(
          user: chat_session.user,
          content: content,
          kind: kind,
          scope: scope,
          scope_id: repository&.id
        )

        SyrusChatMcp.success(id: memory.id, memory: memory_payload(memory))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
