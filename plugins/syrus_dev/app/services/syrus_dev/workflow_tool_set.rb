module SyrusDev
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet

    def self.available_for?(repository)
      McpToolPolicy.syrus_repository?(repository)
    end

    def self.available_for_context?(context)
      McpToolPolicy.syrus_repository?(context.repository) && tool_classes_for(context.role).any?
    end

    def self.tool_definitions(context: nil)
      tool_classes_for(context&.role).map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, context)
      run_context = McpToolContext.from_server_context(context)
      klass = self.class.tool_classes_for(run_context.role).find { |k| k.tool_name == tool_name }
      raise "SyrusDev::WorkflowToolSet: unknown tool #{tool_name.inspect}" unless klass

      klass.call(**params, server_context: context)
    end

    def self.tool_classes_for(role)
      case role
      when nil
        [ ReadPerformanceDiagnosticsTool, ReadSyrusLogsTool, ReadWorkspaceReuseOutcomesTool ]
      when AgentRole::WORKFLOW_IMPLEMENT
        [ ReadPerformanceDiagnosticsTool, ReadSyrusLogsTool, ReadWorkspaceReuseOutcomesTool ]
      when AgentRole::AGENT_INSIGHT
        [ ReadSyrusLogsTool ]
      else
        []
      end
    end
  end
end
