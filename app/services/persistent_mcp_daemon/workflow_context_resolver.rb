class PersistentMcpDaemon::WorkflowContextResolver
  Resolved = Struct.new(:server_context, :allowed_tools, :tool_context, keyword_init: true)

  class << self
    def resolve(raw_server_context)
      meta = raw_server_context&.[](:_meta)
      identity = raw_server_context&.[](:identity)
      token = meta && meta[PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY]

      invocation = McpInvocationContext.resolve(token, worker_id: identity && identity[:worker_id])
      unless invocation.surface == :run
        raise McpInvocationContext::Malformed, "invocation token surface #{invocation.surface.inspect} is not run"
      end

      tool_context = invocation.tool_context
      run = tool_context.run
      Resolved.new(
        server_context: { run_id: run.id, run: run, _meta: meta },
        allowed_tools: McpToolPolicy.for(tool_context) + Mcp::Sidecar.plugin_workflow_tools_for(tool_context),
        tool_context: tool_context
      )
    end
  end
end
