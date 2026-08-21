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
  class << self
    # Idempotent: safe to call for the same tool class more than once. Layers
    # ON TOP of Mcp::Sidecar.authorize_tool (prepended first) so tools that
    # read Mcp::Tools::AuthorizationSupport.current_server_context still see
    # the resolved chat_session/current_message this module reconstructs,
    # not the raw (chat_session-less) server_context the daemon's static
    # MCP::Server was built with.
    def wrap(tool)
      Mcp::Sidecar.authorize_tool(tool)
      tool.singleton_class.prepend(Dispatch) unless tool.singleton_class < Dispatch
      tool
    end
  end

  module Dispatch
    def call(*args, server_context: nil, **kwargs, &block)
      resolved = PersistentMcpDaemon::ChatContextResolver.resolve(server_context)
      return Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(self)

      super(*args, server_context: resolved.server_context, **kwargs, &block)
    rescue McpInvocationContext::InvalidContext => e
      Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}")
    end
  end
end
