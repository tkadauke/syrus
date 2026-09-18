module Syrus
  module Plugin
    # Interface module for chat MCP tool set implementations.
    #
    # Include this module in any class registered as a :chat_mcp_tool_set
    # extension point. The class must implement:
    #
    #   .tool_definitions(tier:)                   -> [{name:, description:, input_schema:}, ...]
    #   .available_for?(chat_session, tier:)       -> bool
    #   #handle(tool_name, params, server_context) -> MCP::Tool::Response
    #
    # == Tool policy
    #
    # A definition may carry policy flags, which is how a plugin's tool takes
    # part in the rules core applies to its own chat tools rather than sitting
    # outside them:
    #
    #   { name: "list_scheduled_tasks", ..., evaluator: true }
    #
    # * +evaluator+ offers the tool to the disposable scoped-event evaluator,
    #   whose tool set is otherwise a fixed read-only allowlist in
    #   McpToolPolicy that a plugin cannot join. Only mark read-only tools.
    #
    # Defaults to false, so a tool set that says nothing behaves exactly as
    # it did before the flag existed.
    module ChatMcpToolSet
    end
  end
end
