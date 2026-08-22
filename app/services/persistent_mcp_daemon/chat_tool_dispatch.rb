require "mcp"

# Wraps a chat MCP::Tool class so it can be safely dispatched from the
# persistent MCP sidecar daemon (EPIC-250), which registers ONE static tool
# list for its whole process lifetime (MCP::Server has no per-request tool
# list hook) even though chat tool availability legitimately varies per
# chat session, tier (essential/deferred), role (planner/coding/local/
# admin/supervisor), and feature flag -- exactly what
# Mcp::Sidecar.chat_tools_for computes once per stdio subprocess.
#
# The daemon instead registers the full known chat tool surface (see
# PersistentMcpDaemon#chat_tools) and this module enforces the same
# tiering/role/feature-flag policy PersistentMcpDaemon::ChatContextResolver
# computes at CALL TIME: #call resolves the signed McpInvocationContext token
# carried in this request's `_meta`, rebuilds the stdio-equivalent
# {chat_session:, current_message:, ...} server_context, and denies
# (not_authorized) any tool not in that session/tier/role's allowed set. So
# `tools/list` over the persistent transport advertises a superset of what
# any single chat turn can actually call -- a known, documented gap (see
# config/syrus_docs/persistent_mcp_sidecar.md) versus stdio mode's exactly
# tier-scoped list; the SECURITY boundary (which tools a given chat turn can
# actually invoke) is unaffected because it is enforced here, not by list
# visibility.
module PersistentMcpDaemon::ChatToolDispatch
  # MCP::Tool.inherited resets these on every subclass (see mcp gem's
  # tool.rb) so a bare `Class.new(tool)` loses its name/description/schema;
  # #wrap copies them back explicitly instead of re-declaring through the
  # tool_name/description/... DSL, which round-trips through type coercion
  # (e.g. annotations expects snake_case kwargs but #to_h emits camelCase)
  # that doesn't losslessly survive a copy.
  METADATA_IVARS = %i[
    @name_value @title_value @description_value @icons_value
    @input_schema_value @output_schema_value @annotations_value @meta_value
  ].freeze

  class << self
    # Builds a daemon-only subclass of `tool` rather than mutating `tool`
    # itself. `tool` is the SAME class object the stdio chat sidecars
    # dispatch directly (McpToolRegistry.tools(surface: :chat)) -- prepending
    # Dispatch onto `tool.singleton_class` in place would permanently require
    # a signed McpInvocationContext token for every future call to that
    # class, including stdio calls in the very same process (e.g. every
    # other spec sharing an RSpec worker with one that boots this daemon).
    # Subclassing keeps the daemon's context-resolution requirement scoped to
    # dispatches that actually go through this daemon.
    def wrap(tool)
      Mcp::Sidecar.authorize_tool(tool)

      daemon_tool = Class.new(tool)
      METADATA_IVARS.each { |ivar| daemon_tool.instance_variable_set(ivar, tool.instance_variable_get(ivar)) }
      daemon_tool.singleton_class.prepend(Dispatch)
      daemon_tool
    end
  end

  module Dispatch
    def call(*args, server_context: nil, **kwargs, &block)
      resolved = PersistentMcpDaemon::ChatContextResolver.resolve(server_context)
      # `self` here is the daemon-only subclass #wrap created, not the
      # original tool class ChatContextResolver's allowed_tools list names --
      # `<=` (subclass-or-equal) matches across that wrap instead of identity.
      return Mcp::Tools.not_authorized unless resolved.allowed_tools.any? { |allowed_tool| self <= allowed_tool }

      super(*args, server_context: resolved.server_context, **kwargs, &block)
    rescue McpInvocationContext::InvalidContext => e
      Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}")
    end
  end
end
