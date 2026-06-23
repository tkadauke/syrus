module SyrusChatMcp
  module AdminPendingActionToolSupport
    private

    def admin_chat_session(server_context)
      chat_session = server_context.fetch(:chat_session)
      return chat_session if chat_session.user.admin?

      nil
    end

    def require_admin(server_context)
      chat_session = admin_chat_session(server_context)
      return chat_session if chat_session

      SyrusChatMcp.unauthorized("Admin access required")
    end

    def create_pending_admin_action(chat_session:, action:, payload:, message:)
      pending_action = chat_session.pending_actions.create!(
        action: action,
        payload: payload,
        requested_by: "agent"
      )

      SyrusChatMcp.success(
        pending_confirmation_id: pending_action.id,
        pending_action_id: pending_action.id,
        state: pending_action.state,
        message: message
      )
    rescue ActiveRecord::RecordInvalid => e
      SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
    end

    def integer_param(value, name)
      integer = Integer(value, exception: false)
      return integer if integer

      SyrusChatMcp.invalid("#{name} is required")
    end
  end
end
