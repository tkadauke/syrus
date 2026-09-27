class PersistentMcpDaemon::WorkflowContextResolver
  Resolved = Struct.new(:server_context, :allowed_tools, :allowed_tool_names, :tool_context, :provider, keyword_init: true)

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
      server_context = {
        run: tool_context.run,
        run_id: tool_context.run.id,
        _meta: meta
      }.compact
      allowed_tools = allowed_tools_for(tool_context)

      Resolved.new(
        server_context: server_context,
        allowed_tools: allowed_tools,
        allowed_tool_names: allowed_tools.map { |tool| McpToolRegistry.tool_name_for(tool) },
        tool_context: tool_context,
        provider: invocation.provider
      )
    end

    private

    def allowed_tools_for(tool_context)
      McpToolPolicy.for(tool_context) + Mcp::Sidecar.plugin_workflow_tools_for(tool_context)
    end
  end
end
