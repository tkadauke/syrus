require "mcp"

module SyrusChatMcp
  class WakeLandingQueueTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "wake_landing_queue"
    description "Request landing queue processing after an operator repair. Requires operator confirmation."

    input_schema(
      properties: {
        reason: { type: "string", description: "Operator-facing audit reason for waking the landing queue." }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "wake_landing_queue",
          payload: { "reason" => reason.to_s },
          reason: reason,
          message: "Wake the landing queue?"
        )
      end
    end
  end
end
