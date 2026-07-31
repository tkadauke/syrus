require "mcp"

module Mcp::Tools
  class RunCommandTool < MCP::Tool
    tool_name "run_command"

    description <<~DESC
      Run a shell command in the operator's local repository root.
      Commands are unrestricted and run with the operator's permissions (trust-based).
      Use for tests, builds, log inspection, and other development workflows.
      Only run commands the operator has explicitly requested or that are clearly safe and reversible.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(
      properties: {
        command: { type: "string", description: "Shell command to run in the repository root." }
      },
      required: %w[command]
    )

    class << self
      def call(command:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        Mcp::Tools::LocalToolDispatch.call("run_command", { command: command }, chat_session: chat_session)
      end
    end
  end
end
