require "mcp"

# A second "prove the pipe" tool alongside PersistentMcpDaemon::PingTool
# (EPIC-250). Where PingTool proves the daemon can accept and answer a call
# at all, this tool proves the per-invocation context boundary
# (McpInvocationContext) works over the real MCP transport: it resolves
# whatever signed invocation token the caller attached to this request's
# `_meta` (PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY) and echoes back
# safe identifying fields reconstructed from it -- proof that one daemon
# process serving many concurrent runs/chats can reconstruct per-call
# context (McpToolContext.from_run / .from_chat_session, same as stdio
# mode) without any shared "current run"/"current chat" state. It is
# intentionally not part of SyrusMcp::CoreToolSet or McpToolRegistry; no
# real workflow/chat capability is wired to it yet.
class PersistentMcpDaemon::InvocationContextTool < MCP::Tool
  tool_name "daemon_invocation_context"

  description "Resolves the signed per-invocation context attached to this request's _meta and echoes back identifying fields. Proves context reconstruction/isolation for the persistent MCP sidecar daemon skeleton; carries no other capability."

  input_schema(properties: {})

  class << self
    def call(server_context: {})
      identity = server_context[:identity] || {}
      meta = server_context[:_meta]
      token = meta.is_a?(Hash) ? meta[PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY] : nil

      resolved = McpInvocationContext.resolve(token, worker_id: identity[:worker_id])
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(ok: true, **safe_payload(resolved)) } ])
    rescue McpInvocationContext::InvalidContext => e
      MCP::Tool::Response.new(
        [ { type: "text", text: JSON.generate(ok: false, error: e.class.name.demodulize, message: e.message) } ],
        error: true
      )
    end

    private

    def safe_payload(resolved)
      context = resolved.tool_context
      {
        surface: resolved.surface,
        role: context.role,
        run_id: context.run&.id,
        job_id: context.job&.id,
        chat_session_id: context.chat_session&.id,
        current_message_id: resolved.current_message_id,
        tier: resolved.tier,
        provider: resolved.provider
      }.compact
    end
  end
end
