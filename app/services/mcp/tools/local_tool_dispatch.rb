module Mcp::Tools
  module LocalToolDispatch
    DISCONNECTED_ERROR = "Local daemon not connected. Run `syrus local` in your repo to continue."
    CONFIRMATION_REQUIRED_TOOLS = Permissions::LocalModeActions::TOOL_NAMES

    def self.call(tool_name, arguments, chat_session:, server_context: nil)
      if confirmation_required?(tool_name) && !daemon_connected?(chat_session)
        return execute_now(tool_name, arguments, chat_session:)
      end

      if confirmation_required?(tool_name)
        authorization = Permissions::LocalModeAuthorization.authorize(chat_session:, tool_name:, arguments:)
        return not_permitted_error(tool_name) if authorization.denied?
        return create_pending_confirmation(tool_name, arguments, chat_session:, server_context:) unless authorization.allowed?
      end

      execute_now(tool_name, arguments, chat_session:)
    end

    def self.execute_now(tool_name, arguments, chat_session:)
      session = chat_session.local_daemon_session
      return Mcp::Tools.tool_error(DISCONNECTED_ERROR) unless session&.connected?

      call = session.dispatch_tool_call!(tool_name, arguments)
      outcome = call.wait_for_result

      if outcome.nil?
        Mcp::Tools.tool_error(call.reload.error.presence || "Local daemon tool call failed.")
      elsif outcome.is_a?(Hash) && (outcome[:error].present? || outcome["error"].present?)
        Mcp::Tools.with_execution_authority(
          Mcp::Tools.tool_error((outcome[:error] || outcome["error"]).to_s),
          "operator_host"
        )
      else
        Mcp::Tools.with_execution_authority(Mcp::Tools.success(outcome), "operator_host")
      end
    end

    def self.confirmation_required?(tool_name)
      CONFIRMATION_REQUIRED_TOOLS.include?(tool_name.to_s)
    end

    def self.daemon_connected?(chat_session)
      chat_session.local_daemon_session&.connected?
    end

    def self.not_permitted_error(tool_name)
      Mcp::Tools.tool_error("#{tool_label(tool_name).capitalize} is denied by a permission rule for Local Mode.")
    end

    def self.create_pending_confirmation(tool_name, arguments, chat_session:, server_context:)
      pending_action = nil
      ApplicationRecord.transaction do
        pending_action = chat_session.pending_actions.create!(
          action: "local_tool_call",
          payload: approval_payload(tool_name, arguments),
          requested_by: "agent"
        )

        attach_pending_action_to_current_message(server_context, chat_session, pending_action)
      end

      Mcp::Tools.success(
        pending_confirmation_id: pending_action.id,
        pending_action_id: pending_action.id,
        state: pending_action.state,
        message: "#{tool_label(tool_name)} requires operator confirmation in Local Mode."
      )
    end

    def self.approval_payload(tool_name, arguments)
      {
        "tool_name" => tool_name.to_s,
        "arguments" => comparable_payload(arguments)
      }
    end

    def self.comparable_payload(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h { |key, nested| [ key, comparable_payload(nested) ] }
      when Array
        value.map { |nested| comparable_payload(nested) }
      else
        value
      end
    end

    def self.tool_label(tool_name)
      tool_name.to_s.humanize(capitalize: false)
    end

    def self.attach_pending_action_to_current_message(server_context, chat_session, pending_action)
      message = server_context&.[](:current_message)
      return unless message

      if message.is_a?(ChatMessage)
        chat_session.messages
          .where(pending_action_id: pending_action.id)
          .where.not(id: message.id)
          .update_all(pending_action_id: nil)
      end

      message.update_columns(pending_action_id: pending_action.id)
    end
  end
end
