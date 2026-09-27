module PersistentMcpDaemon::WorkflowToolDispatch
  class << self
    def wrap(tool)
      tool.singleton_class.prepend(Dispatch) unless tool.singleton_class < Dispatch
      tool
    end
  end

  module Dispatch
    def call(*args, server_context: nil, **kwargs, &block)
      daemon_identity = server_context&.[](:identity)
      return super(*args, server_context: server_context, **kwargs, &block) if daemon_identity.blank?

      begin
        resolved = PersistentMcpDaemon::WorkflowContextResolver.resolve(server_context)
      rescue McpInvocationContext::InvalidContext => e
        return McpToolUsageRecorder.record_dispatch(
          surface: "workflow", tool_name: name_value, tool_input: kwargs,
          sidecar_mode: "persistent", daemon_identity: daemon_identity,
          error_class: e.class.name
        ) { Mcp::Tools.unauthorized("invocation context #{e.class.name.demodulize}: #{e.message}") }
      end

      run = resolved.tool_context.run
      McpToolUsageRecorder.record_dispatch(
        surface: "workflow", tool_name: name_value, tool_input: kwargs,
        sidecar_mode: "persistent", daemon_identity: daemon_identity,
        run: run, provider: run.agent_provider
      ) do
        next Mcp::Tools.not_authorized unless resolved.allowed_tools.include?(self)

        super(*args, server_context: resolved.server_context, **kwargs, &block)
      end
    end
  end
end
