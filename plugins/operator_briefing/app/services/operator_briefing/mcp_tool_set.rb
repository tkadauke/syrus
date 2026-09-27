require "mcp"

module OperatorBriefing
  class McpToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_CLASSES = [
      Tools::SubmitBriefingBlockTool,
      Tools::ListBriefingTopicsTool,
      Tools::ReadBriefingTopicTool,
      Tools::SubmitDiveReportTool
    ].freeze

    def self.available_for?(_repository) = OperatorBriefing.enabled?

    def self.available_for_context?(context)
      OperatorBriefing.enabled? && context.run? && tool_classes_for(context).any?
    end

    def self.tool_definitions(context: nil)
      return [] if context && !available_for_context?(context)

      tool_classes_for(context).map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      context = McpToolContext.from_run(Mcp::Tools.run_from_context(server_context))
      klass = self.class.tool_classes_for(context).find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown Operator Briefing tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[OperatorBriefing::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def self.tool_classes_for(context)
      return TOOL_CLASSES unless context

      step_kind = context.run&.step&.kind
      if step_kind == "briefing_generate_run"
        [ Tools::SubmitBriefingBlockTool ]
      elsif step_kind == "submit_dive_report"
        [ Tools::ListBriefingTopicsTool, Tools::ReadBriefingTopicTool, Tools::SubmitDiveReportTool ]
      else
        []
      end
    end
  end
end
