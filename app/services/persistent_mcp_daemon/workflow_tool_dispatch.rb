require "mcp"

module PersistentMcpDaemon::WorkflowToolDispatch
  class << self
    # Installs the capability authorization layer first, as the stdio sidecar
    # and ChatToolDispatch do, so it sits inside this wrapper and sees the
    # resolved run context. Without it a permission-gated workflow-only tool
    # (patch_workflow, read_artifact) never reached ScheduledAuthorization in
    # persistent mode, so a scheduled run skipped the owner's rules.
    def wrap(tool)
      Mcp::Sidecar.authorize_tool(tool)
      tool.singleton_class.prepend(Dispatch) unless tool.singleton_class < Dispatch
      tool
    end
  end

  module Dispatch
    def call(*args, server_context: nil, **kwargs, &block)
      daemon_identity = server_context&.[](:identity)
      return super(*args, server_context: server_context, **kwargs, &block) if daemon_identity.blank? || server_context&.[](:workflow_role).blank?

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
        run: run, provider: resolved.provider
      ) do
        next Mcp::Tools.not_authorized unless resolved.allowed_tool_names.include?(McpToolRegistry.tool_name_for(self))

        super(*args, server_context: resolved.server_context, **kwargs, &block)
      end
    rescue StandardError => e
      Mcp::Tools.exception_response(e)
    end
  end
end
