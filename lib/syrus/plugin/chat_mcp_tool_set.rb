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
    # * +coworker_safe+ explicitly opts a definition into coworker chats.
    #   Definitions are excluded there by default, including credential-backed
    #   tool sets, and should also name their required capability. A tool set
    #   must additionally implement `.available_for_coworker?`; its absence is
    #   the deny-by-default behavior. Each safe definition must include a
    #   `capability:` value held by the coworker or it is still excluded.
    #   A harmless tool may instead declare `ungated: true`; this is reserved
    #   for tools with no effects outside the coworker's workspace or chat,
    #   no data beyond the owner's visibility, and no external cost.
    #
    # A provider may declare `.coworker_grants`, returning hashes accepted by
    # `Coworkers::GrantCatalog::Descriptor`: name, label, description,
    # maximum_policy, tools, and optional scope callbacks. Scopeable grants
    # provide `scope_options_callback`, `scope_label_callback`, and
    # `valid_scope_callback`. Only enabled providers are collected.
    module ChatMcpToolSet
    end
  end
end
