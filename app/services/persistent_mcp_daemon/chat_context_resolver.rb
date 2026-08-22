# Reconstructs a stdio-equivalent MCP dispatch context for a chat tool call
# arriving over the persistent MCP sidecar daemon (EPIC-250).
#
# Stdio chat sidecars (Mcp::Sidecar.chat) get a fresh subprocess per
# (chat_session, tier), so Mcp::Sidecar.chat_context/#chat_tools_for compute
# an accurately-scoped {chat_session:, current_message:, ...} server_context
# and tool list exactly once, at process boot, for that one chat turn. The
# persistent daemon is a single process serving many concurrent chat turns
# across many sessions/tiers/roles, so neither can be computed once at server
# boot -- #resolve rebuilds both, per call, from the signed
# McpInvocationContext token the dispatching request attached to `_meta`
# (see PersistentMcpDaemon::ChatToolDispatch, the wrapper that calls this).
class PersistentMcpDaemon::ChatContextResolver
  Resolved = Struct.new(:server_context, :allowed_tools, :tool_context, keyword_init: true)

  class << self
    # Raises McpInvocationContext::InvalidContext (a caller-visible rejection
    # reason) when the token is missing, malformed, expired, minted for a
    # different worker, or the chat session it names is gone -- callers
    # convert that into a not_authorized/error tool response, never a crash.
    def resolve(raw_server_context)
      # `raw_server_context` is an MCP::ServerContext (the mcp gem wraps
      # EVERY dispatch, stdio or persistent, in this class whenever a tool's
      # #call accepts server_context:) -- it delegates Hash methods like #[]
      # to its underlying context via method_missing, so `&.[]` (rather than
      # an `is_a?(Hash)` guard, which would always be false here) is what
      # actually reads through the wrapper.
      meta = raw_server_context&.[](:_meta)
      identity = raw_server_context&.[](:identity)
      token = meta && meta[PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY]

      invocation = McpInvocationContext.resolve(token, worker_id: identity && identity[:worker_id])
      unless invocation.surface == :chat
        raise McpInvocationContext::Malformed, "invocation token surface #{invocation.surface.inspect} is not chat"
      end

      tool_context = invocation.tool_context
      server_context = {
        chat_session: tool_context.chat_session,
        current_message: current_message_for(tool_context.chat_session, invocation.current_message_id),
        evaluator: tool_context.role == AgentRole::CHAT_EVALUATOR ? true : nil,
        scoped_event_id: invocation.scoped_event_id,
        evaluator_session_id: invocation.evaluator_session_id,
        _meta: meta
      }.compact

      Resolved.new(
        server_context: server_context,
        allowed_tools: allowed_tools_for(tool_context, tier: invocation.tier),
        tool_context: tool_context
      )
    end

    private

    def current_message_for(chat_session, current_message_id)
      return Mcp::Tools::CurrentMessage.new(chat_session) if current_message_id.blank?

      chat_session.messages.find_by(id: current_message_id) || Mcp::Tools::CurrentMessage.new(chat_session)
    end

    # Mirrors Mcp::Sidecar.chat_tools_for's gating exactly (McpToolPolicy for
    # the evaluator role; McpToolRegistry.tools_for_context + the supervisor
    # exclusion list otherwise) so a tool that's off-limits for this
    # session/tier/role is rejected identically regardless of transport, even
    # though the daemon's tools/list advertises the full known chat tool
    # surface (see PersistentMcpDaemon::ChatToolDispatch for why).
    def allowed_tools_for(tool_context, tier:)
      return McpToolPolicy.for(tool_context) if tool_context.role == AgentRole::CHAT_EVALUATOR

      registry_tier = tier.to_s == "deferred" ? :deferred : :essential
      allowed = McpToolRegistry.tools_for_context(tool_context, surface: :chat, tier: registry_tier)
      return allowed unless tool_context.chat_session&.system_kind_supervisor?

      allowed - McpToolPolicy::SUPERVISOR_EXCLUDED_TOOLS
    end
  end
end
