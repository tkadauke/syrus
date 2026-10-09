module Mcp::Tools
  module LocalToolDispatch
    DISCONNECTED_ERROR = "Local daemon not connected. Run `syrus local` in your repo to continue."

    def self.call(tool_name, arguments, chat_session:)
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
  end
end
