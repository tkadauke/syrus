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
    #   { name: "schedule_recurring", ..., supervisor_excluded: true }
    #   { name: "list_scheduled_tasks", ..., evaluator: true }
    #
    # * +supervisor_excluded+ keeps the tool out of Supervisor chats. Plugin
    #   tools are appended after core's supervisor filter runs, so without
    #   this flag a plugin tool is always offered there -- which is wrong for
    #   anything that creates or fires work.
    # * +evaluator+ offers the tool to the disposable scoped-event evaluator,
    #   whose tool set is otherwise a fixed read-only allowlist in
    #   McpToolPolicy that a plugin cannot join. Only mark read-only tools.
    #
    # Both default to false, so a tool set that says nothing behaves exactly
    # as it did before the flags existed.
    module ChatMcpToolSet
    end
  end
end
