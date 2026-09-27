require "mcp"

module OperatorBriefing
  class McpToolSet
    TOOL_CLASSES = [
      Tools::SubmitBriefingBlockTool,
      Tools::ReadBriefingGitDiffTool,
      Tools::ListRecentWorkflowsTool
    ].freeze

    def self.available_for_context?(context)
      OperatorBriefing.enabled? && context.run? && context.run&.step&.kind == "briefing_generate_run"
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
      context = McpToolContext.from_server_context(server_context)
      return Mcp::Tools.unauthorized("Operator Briefing tools are only available to briefing generation runs") unless self.class.available_for_context?(context)

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown Operator Briefing tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[OperatorBriefing::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
