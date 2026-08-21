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
    # Records MCP usage (McpToolUsageRecorder, EPIC-250 authoritative
    # persistent-mode logging) right at this dispatch boundary instead of
    # relying on the calling agent's own transcript, which is what
    # ChatTurnJob#record_agent_event does for stdio-mode calls (see
    # ChatTurnJob#record_transcript_mcp_usage?, which skips that
    # transcript-based recording for a persistent-transport turn so the two
    # don't double-count the same call). Recording here -- rather than
    # trusting the agent CLI to faithfully echo every call/result back over
    # stdout -- is what makes a tier/role rejection or an invalid invocation
    # context (both happen before the wrapped tool ever runs, so a
    # transcript would show at best an opaque error, not a clean tool_result
    # this dispatcher's not_authorized/unauthorized both mimic) show up in
    # `mcp_tool_usages` at all.
    def call(*args, server_context: nil, **kwargs, &block)
      daemon_identity = server_context&.[](:identity)

      begin
        resolved = PersistentMcpDaemon::ChatContextResolver.resolve(server_context)
      rescue McpInvocationContext::InvalidContext => e
        return McpToolUsageRecorder.record_dispatch(
          surface: "chat", tool_name: name_value, tool_input: kwargs,
          sidecar_mode: "persistent", daemon_identity: daemon_identity,
          error_class: e.class.name
        ) { Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}") }
      end

      chat_session = resolved.tool_context.chat_session

      McpToolUsageRecorder.record_dispatch(
        surface: "chat", tool_name: name_value, tool_input: kwargs,
        sidecar_mode: "persistent", daemon_identity: daemon_identity,
        chat_session: chat_session, provider: chat_session&.effective_chat_provider
      ) do
        next Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(self)

        super(*args, server_context: resolved.server_context, **kwargs, &block)
      end
    end
  end
end
