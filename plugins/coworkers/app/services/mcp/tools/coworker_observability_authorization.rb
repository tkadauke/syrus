module Mcp::Tools::CoworkerObservabilityAuthorization
  private

  def observability_authorized?(server_context, tool: self)
    context = McpToolContext.from_server_context(server_context)
    return true if context.user.admin? && !context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

    McpToolRegistry.tool_permitted?(context, tool)
  end

  def observability_unauthorized(server_context)
    context = McpToolContext.from_server_context(server_context)
    message = context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) ? "Observability access required" : "Admin access required"
    Mcp::Tools.unauthorized(message)
  end
end
