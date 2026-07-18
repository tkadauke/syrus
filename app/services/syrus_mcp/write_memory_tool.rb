require "mcp"

module SyrusMcp
  class WriteMemoryTool < MCP::Tool
    extend MemoryToolSupport

    tool_name "write_memory"

    description "Write a persistent memory scoped to the current Job's repository. " \
                "Scope is always 'repository'; author, source_type, and source_id are " \
                "set automatically from the agent run context."

    input_schema(
      properties: {
        content: { type: "string", description: "Memory content (max #{ChatMemory::CONTENT_MAX_LENGTH} characters)." },
        kind: { type: "string", enum: ChatMemory::KIND, description: "Memory kind." }
      },
      required: %w[content kind]
    )

    class << self
      def call(content:, kind:, server_context:)
        run = SyrusMcp.run_from_context(server_context)
        content = content.to_s.strip
        kind = kind.to_s

        return SyrusMcp.invalid("content is required") if content.empty?
        return SyrusMcp.invalid("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind)

        memory = ChatMemory.create!(
          user: run.job.user,
          content: content,
          kind: kind,
          scope: "repository",
          scope_id: run.job.repository_id,
          author: "agent",
          source_type: "run",
          source_id: run.id
        )

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(memory_payload(memory)) } ])
      rescue ActiveRecord::RecordInvalid => e
        SyrusMcp.invalid(e.record.errors.full_messages.to_sentence)
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::WriteMemoryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
