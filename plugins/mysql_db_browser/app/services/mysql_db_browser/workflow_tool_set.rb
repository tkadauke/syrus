module MysqlDbBrowser
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet

    def self.available_for?(_repository)
      MysqlDbBrowser.enabled? && MysqlConnection.where(agentic_access_enabled: true).exists?
    end

    def self.available_for_context?(context)
      context.role == AgentRole::WORKFLOW_IMPLEMENT && available_for?(context.repository)
    end

    def self.tool_definitions(context: nil)
      return [] if context && context.role != AgentRole::WORKFLOW_IMPLEMENT

      ChatToolSet.tool_definitions(tier: :essential)
    end

    def handle(tool_name, params, server_context)
      ChatToolSet.new.handle(tool_name, params, server_context)
    end
  end
end
