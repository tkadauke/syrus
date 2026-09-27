require "mcp"

module PersistentMcpDaemon::ToolDispatch
  class << self
    def wrap(tool)
      Mcp::Sidecar.authorize_tool(tool)
      tool.singleton_class.prepend(Dispatch) unless tool.singleton_class < Dispatch
      tool
    end
  end

  module Dispatch
    def call(*args, server_context: nil, **kwargs, &block)
      daemon_identity = server_context&.[](:identity)
      return super(*args, server_context: server_context, **kwargs, &block) if daemon_identity.blank?

      invocation = resolve_invocation(server_context, daemon_identity)

      if invocation.surface == :chat
        resolved = PersistentMcpDaemon::ChatContextResolver.resolve(server_context)
        chat_session = resolved.tool_context.chat_session

        return McpToolUsageRecorder.record_dispatch(
          surface: "chat", tool_name: name_value, tool_input: kwargs,
          sidecar_mode: "persistent", daemon_identity: daemon_identity,
          chat_session: chat_session, provider: chat_session&.effective_chat_provider
        ) do
          next Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(self)

          super(*args, server_context: resolved.server_context, **kwargs, &block)
        end
      end

      if invocation.surface == :run
        resolved = PersistentMcpDaemon::WorkflowContextResolver.resolve(server_context)
        run = resolved.tool_context.run

        return McpToolUsageRecorder.record_dispatch(
          surface: "workflow", tool_name: name_value, tool_input: kwargs,
          sidecar_mode: "persistent", daemon_identity: daemon_identity,
          run: run, provider: run.agent_provider
        ) do
          next Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(self)

          super(*args, server_context: resolved.server_context, **kwargs, &block)
        end
      end

      raise McpInvocationContext::Malformed, "invocation token surface #{invocation.surface.inspect} is not supported"
    rescue McpInvocationContext::InvalidContext => e
      McpToolUsageRecorder.record_dispatch(
        surface: "chat", tool_name: name_value, tool_input: kwargs,
        sidecar_mode: "persistent", daemon_identity: daemon_identity,
        error_class: e.class.name
      ) { Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}") }
    end

    private

    def resolve_invocation(server_context, daemon_identity)
      meta = server_context&.[](:_meta)
      token = meta && meta[PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY]
      McpInvocationContext.resolve(token, worker_id: daemon_identity && daemon_identity[:worker_id])
    end
  end
end
