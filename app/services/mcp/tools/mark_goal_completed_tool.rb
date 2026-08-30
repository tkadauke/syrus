require "mcp"

module Mcp::Tools
  class MarkGoalCompletedTool < MCP::Tool
    tool_name "mark_goal_completed"

    description <<~DESC
      Mark the active chat goal completed. Only use this when the goal's
      completion condition is actually satisfied.
    DESC

    input_schema(
      properties: {
        reason: { type: "string", description: "Concise reason the goal is complete." },
        details: { type: "object", description: "Optional structured completion details." }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, server_context:, details: nil)
        chat_session = server_context.fetch(:chat_session)
        goal = chat_session.active_goal
        return Mcp::Tools.invalid("active goal not found") unless goal
        return Mcp::Tools.invalid("goal is not active") unless goal.active?

        goal.complete!(reason: Mcp::Tools.utf8(reason).strip.presence || "completed", details: details)
        chat_session.messages.create!(
          role: "system",
          content: {
            "text" => "Goal completed: #{goal.terminal_reason}",
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
