require "mcp"

module Mcp::Tools
  class AdminPauseUserSchedulingTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "admin_pause_user_scheduling"
    description <<~DESC
      Request pausing scheduled task fires for one or more users. Pass
      user_id for a single user (unchanged single-confirmation behavior) or
      user_ids for multiple users, which requires a shared reason (the
      root cause behind pausing every user in the batch) and creates one
      grouped pending action the operator confirms or rejects together.
      Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        user_id: { type: "integer", description: "User id whose scheduling should be paused." },
        user_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple user ids to pause as one grouped pending action, sharing one reason."
        },
        reason: { type: "string", description: "Operator-facing audit reason. Required for user_ids, optional for a single user_id." }
      }
    )

    class << self
      def call(user_id: nil, user_ids: nil, reason: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: user_id, ids: user_ids, param_name: "user_id")
        return error if error
        return Mcp::Tools.invalid("reason is required for user_ids") if bulk && reason.to_s.strip.empty?

        users = ids.map { |id| User.find_by(id: id) }
        missing = ids.zip(users).select { |_id, user| user.nil? }.map(&:first)
        return Mcp::Tools.invalid("user not found: #{missing.join(', ')}") if missing.any?

        unless bulk
          user = users.first
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "admin_pause_user_scheduling",
            payload: { "user_id" => user.id },
            reason: reason,
            message: "Pause scheduling for user ##{user.id} (#{user.email_address})?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: users.map { |user|
            { action: "admin_pause_user_scheduling", payload: { "user_id" => user.id }, requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Pause scheduling for #{users.size} users?")
      end
    end
  end
end
