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
    # A definition may provide +capability_descriptor:+ using the canonical
    # Permissions::CapabilityDescriptor contract. A plugin may temporarily
    # ratchet existing hashes through manifest-owned
    # +capability_descriptor_compatibility+ digests while it migrates.
    # Coworkers inherit ordinary chat definitions and availability by default;
    # canonical capability descriptors still decide whether calls run, ask, or
    # are denied. A definition may opt out with +coworker_excluded:+ or
    # +admin_only:+. A provider whose entire surface is incoherent for coworkers
    # may return true from `.coworker_excluded?`. Providers that contribute a
    # distinct coworker-only surface may return true from
    # `.coworker_specific_availability?` and implement `.available_for_coworker?`.
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
