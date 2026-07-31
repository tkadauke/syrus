module Mcp::Tools
  module AdminPendingActionToolSupport
    include ProposalToolSupport

    private

    def admin_chat_session(server_context)
      chat_session = server_context.fetch(:chat_session)
      return chat_session if chat_session.user.admin?

      nil
    end

    def require_admin(server_context)
      chat_session = admin_chat_session(server_context)
      return chat_session if chat_session

      Mcp::Tools.unauthorized("Admin access required")
    end

    def create_pending_admin_action(server_context:, chat_session:, action:, payload:, message:, reason: nil)
      pending_action = create_pending_action_for_current_message!(
        server_context,
        chat_session,
        action: action,
        payload: payload,
        reason: reason,
        requested_by: "agent"
      )

      Mcp::Tools.success(
        pending_confirmation_id: pending_action.id,
        pending_action_id: pending_action.id,
        state: pending_action.state,
        reason: pending_action.reason,
        message: message
      )
    rescue ActiveRecord::RecordInvalid => e
      Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
    end

    def integer_param(value, name)
      integer = Integer(value, exception: false)
      return integer if integer

      Mcp::Tools.invalid("#{name} is required")
    end
  end
end
