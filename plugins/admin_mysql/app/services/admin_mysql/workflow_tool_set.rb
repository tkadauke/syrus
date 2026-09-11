module AdminMysql
  class WorkflowToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_CLASSES = [
      StatusTool
    ].freeze

    def self.available_for?(repository)
      AdminMysql.mysql? && McpToolPolicy.syrus_repository?(repository)
    end

    def self.available_for_context?(context)
      context.role == AgentRole::WORKFLOW_IMPLEMENT && available_for?(context.repository)
    end

    def self.tool_definitions(context: nil)
      return [] if context && context.role != AgentRole::WORKFLOW_IMPLEMENT

      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      context = McpToolContext.from_server_context(server_context)
      return Mcp::Tools.unauthorized("Admin MySQL workflow tools are only available to implement runs") unless self.class.available_for_context?(context)

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown Admin MySQL workflow tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[AdminMysql::WorkflowToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
