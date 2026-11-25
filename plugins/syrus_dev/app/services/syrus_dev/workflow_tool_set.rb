module SyrusDev
  class WorkflowToolSet
    include Syrus::Host::McpToolSet

    OPERATIONS = {
      "read_performance_diagnostics" => "syrus_dev.performance/read@v1",
      "read_syrus_logs" => "syrus_dev.logs/search@v1",
      "read_workspace_reuse_outcomes" => "syrus_dev.workspace_reuse/read@v1"
    }.freeze

    def self.available_for?(repository)
      Syrus::Host::McpToolPolicy.syrus_repository?(repository)
    end

    def self.available_for_context?(context)
      Syrus::Host::McpToolPolicy.syrus_repository?(context.repository) && tool_classes_for(context.role).any?
    end

    def self.tool_definitions(context: nil)
      tool_classes_for(context&.role).map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h,
          capability_descriptor: PermissionProvider.capability_descriptor(OPERATIONS.fetch(klass.tool_name))
        }
      end
    end

    def handle(tool_name, params, context)
      run_context = Syrus::Host::ToolContext.from_server_context(context)
      klass = self.class.tool_classes_for(run_context.role).find { |k| k.tool_name == tool_name }
      raise "SyrusDev::WorkflowToolSet: unknown tool #{tool_name.inspect}" unless klass

      klass.call(**params, server_context: context)
    end

    def self.tool_classes_for(role)
      case role
      when nil
        [ ReadPerformanceDiagnosticsTool, ReadSyrusLogsTool, ReadWorkspaceReuseOutcomesTool ]
      when Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT
        [ ReadPerformanceDiagnosticsTool, ReadSyrusLogsTool, ReadWorkspaceReuseOutcomesTool ]
      when Syrus::Host::AgentRole::AGENT_INSIGHT
        [ ReadSyrusLogsTool ]
      else
        []
      end
    end
  end
end
