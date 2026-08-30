module DesignDocs
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_CLASSES = [
      ListDesignDocsTool,
      ReadDesignDocTool
    ].freeze

    def self.available_for?(repository)
      DesignDocs.enabled? && repository.present?
    end

    def self.available_for_context?(context)
      context.run? && AgentRole::WORKFLOW_ROLES.include?(context.role) && available_for?(context.repository)
    end

    def self.tool_definitions(context: nil)
      return [] if context && !available_for_context?(context)

      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown design docs workflow tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
