require "mcp"

module Mcp::Tools
  class AdminReadMemoryAuditHistoryTool < MCP::Tool
    tool_name "admin_read_memory_audit_history"

    description "Read the full audit-event history for a ChatMemory (create/update/delete, " \
                "before/after content, kind, confidence, actor, timestamp), including memories " \
                "that have since been soft-deleted. Admin only."

    input_schema(
      properties: {
        memory_id: { type: "integer", description: "ChatMemory id to read audit history for." }
      },
      required: %w[memory_id]
    )

    class << self
      def call(memory_id:, server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        memory = ChatMemory.find_by(id: memory_id)
        return Mcp::Tools.invalid("memory not found: #{memory_id}") unless memory

        Mcp::Tools.success(
          memory_id: memory.id,
          deleted: memory.deleted?,
          audit_events: memory.chat_memory_audit_events.map { |event| event_payload(event) }
        )
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def event_payload(event)
        {
          id: event.id,
          event_type: event.event_type,
          actor_kind: event.actor_kind,
          actor_user_id: event.actor_user_id,
          actor_run_id: event.actor_run_id,
          previous_content: event.previous_content,
          new_content: event.new_content,
          previous_kind: event.previous_kind,
          new_kind: event.new_kind,
          previous_confidence: event.previous_confidence,
          new_confidence: event.new_confidence,
          created_at: event.created_at.iso8601
        }
      end
    end
  end
end
