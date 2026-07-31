module Mcp::Tools
  module LocalToolDispatch
    DISCONNECTED_ERROR = "Local daemon not connected. Run `syrus local` in your repo to continue."

    def self.call(tool_name, arguments, chat_session:)
      session = chat_session.local_daemon_session
      return Mcp::Tools.tool_error(DISCONNECTED_ERROR) unless session&.connected?

      call = session.dispatch_tool_call!(tool_name, arguments)
      outcome = call.wait_for_result

      if outcome[:error]
        Mcp::Tools.tool_error(outcome[:error].to_s)
      else
        Mcp::Tools.success(outcome[:result])
      end
    end
  end
end
