require "mcp"

module Mcp::Tools
  class MarkGoalBlockedTool < MCP::Tool
    tool_name "mark_goal_blocked"

    description <<~DESC
      Mark the active chat goal blocked. Only use this when you cannot make
      meaningful progress without operator input or an external state change.
      Agents cannot pause, resume, stop, or cancel goals.
    DESC

    input_schema(
      properties: {
        reason: { type: "string", description: "Concise machine-readable or human-readable blocked reason." },
        details: { type: "object", description: "Optional structured blocked details." }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, server_context:, details: nil)
        chat_session = server_context.fetch(:chat_session)
        goal = chat_session.active_goal
        return Mcp::Tools.invalid("active goal not found") unless goal
        return Mcp::Tools.invalid("goal is not active") unless goal.active?

        normalized_reason = Mcp::Tools.utf8(reason).strip
        return Mcp::Tools.invalid("reason is required") if normalized_reason.blank?

        goal.block!(reason: normalized_reason, details: details)
        chat_session.messages.create!(
          role: "system",
          content: {
            "text" => "Goal blocked: #{goal.terminal_reason}",
            "source" => "goal_loop",
            "chat_goal_id" => goal.id
          }
        )
        chat_session.broadcast_controls
        Mcp::Tools.success(goal_id: goal.id, status: goal.status, reason: goal.terminal_reason)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
