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
#
# #wrap must NOT mutate the tool class itself (e.g. via
# `tool.singleton_class.prepend`): that class object is the exact same one
# McpToolRegistry and Mcp::Sidecar hand to every OTHER caller in this
# process -- including stdio chat dispatch and every spec that calls a tool
# directly with a plain server_context Hash. An earlier version prepended
# the invocation-context requirement onto the tool class itself, which made
# it permanently reject any direct, non-daemon call for the rest of the
# process once a single PersistentMcpDaemon had built its tool list -- a
# correctness bug in production (a shared process could serve both
# transports) that showed up in tests as unrelated chat tool specs failing
# whenever they ran after a persistent-daemon spec in the same worker. So
# #wrap instead builds a standalone dispatch proxy subclass and leaves the
# original tool untouched.
module PersistentMcpDaemon::ChatToolDispatch
  # MCP::Tool.inherited resets exactly these ivars to nil on every
  # subclassing (see the `mcp` gem's Tool.inherited); re-copied from the
  # original tool so the proxy keeps its name/description/schema/etc.
  # without redeclaring any of it.
  COPIED_IVARS = %i[
    @name_value @title_value @description_value @icons_value
    @input_schema_value @output_schema_value @annotations_value @meta_value
  ].freeze

  class << self
    # Idempotent: safe to call for the same tool class more than once --
    # returns the same proxy subclass instead of building a new one each
    # time.
    def wrap(tool)
      Mcp::Sidecar.authorize_tool(tool)
      proxies[tool] ||= build_proxy(tool)
    end

    def dispatch(tool, *args, server_context:, **kwargs, &block)
      resolved = PersistentMcpDaemon::ChatContextResolver.resolve(server_context)
      return Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(tool)

      tool.call(*args, server_context: resolved.server_context, **kwargs, &block)
    rescue McpInvocationContext::InvalidContext => e
      Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}")
    end

    private

    def proxies
      @proxies ||= {}
    end

    def build_proxy(tool)
      Class.new(tool) do
        PersistentMcpDaemon::ChatToolDispatch::COPIED_IVARS.each do |ivar|
          instance_variable_set(ivar, tool.instance_variable_get(ivar))
        end

        define_singleton_method(:call) do |*args, server_context: nil, **kwargs, &block|
          PersistentMcpDaemon::ChatToolDispatch.dispatch(tool, *args, server_context: server_context, **kwargs, &block)
        end
      end
    end
  end
end
