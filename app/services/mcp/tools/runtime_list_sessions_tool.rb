require "mcp"

module Mcp::Tools
  class RuntimeListSessionsTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_list_sessions"

    description <<~DESC
      List Runtime Sessions (DOC-17) attached to this Coding Mode chat --
      live dev servers/apps/processes the agent can build, launch, snapshot,
      inspect, and (with a control lease) interact with. Includes stopped and
      failed sessions so history stays visible; check `state` to find the
      active one.
    DESC

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        sessions = chat_session.runtime_sessions.order(:created_at).map { |session| runtime_session_payload(session) }
        Mcp::Tools.success(sessions: sessions)
      end
    end
  end
end
