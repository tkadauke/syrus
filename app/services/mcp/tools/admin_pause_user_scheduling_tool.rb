require "mcp"

module Mcp::Tools
  class AdminPauseUserSchedulingTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_pause_user_scheduling"
    description "Request pausing scheduled task fires for a user. Requires operator confirmation."

    input_schema(
      properties: {
        user_id: { type: "integer", description: "User id whose scheduling should be paused." }
      },
      required: %w[user_id]
    )

    class << self
      def call(user_id:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        user_id = integer_param(user_id, "user_id")
        return user_id if user_id.is_a?(MCP::Tool::Response)

        user = User.find_by(id: user_id)
        return Mcp::Tools.invalid("user not found: #{user_id}") unless user

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_pause_user_scheduling",
          payload: { "user_id" => user.id },
          message: "Pause scheduling for user ##{user.id} (#{user.email_address})?"
        )
      end
    end
  end
end
