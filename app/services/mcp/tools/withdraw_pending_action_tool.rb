require "mcp"

module Mcp::Tools
  class WithdrawPendingActionTool < MCP::Tool
    tool_name "withdraw_pending_action"

    description <<~DESC
      Immediately withdraw an unconfirmed pending action created in this chat.
      Pending actions are rejected and queued or otherwise cancellable actions
      are cancelled. This never creates another confirmation request.
    DESC

    input_schema(
      properties: {
        pending_action_id: { type: "integer", description: "ID of the pending action to withdraw." },
        reason: { type: "string", maxLength: 500, description: "Optional concise reason for withdrawing it." }
      },
      required: %w[pending_action_id]
    )

    class << self
      def call(pending_action_id:, server_context:, reason: nil)
        chat_session = server_context.fetch(:chat_session)
        id = Integer(pending_action_id, exception: false)
        return Mcp::Tools.invalid("pending action not found in this chat") unless id

        action = chat_session.pending_actions.find_by(id: id, user_id: chat_session.user_id)
        return Mcp::Tools.invalid("pending action not found in this chat") unless action

        result = PendingActions::Withdrawal.new(action, user: chat_session.user, reason: reason).call
        Mcp::Tools.success(result.to_h)
      rescue PendingActions::Withdrawal::GroupedAction, PendingActions::Withdrawal::NotWithdrawable => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("pending action not found in this chat")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
