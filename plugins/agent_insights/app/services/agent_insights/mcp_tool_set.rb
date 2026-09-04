require "mcp"

module AgentInsights
  # Tools for the agent_insight surface: an insight run submits, updates, and
  # retires suggestions; chat gets the read-only pair.
  class McpToolSet
    TOOL_CLASSES = [
      Tools::SubmitInsightTool,
      Tools::UpdateInsightTool,
      Tools::RetireInsightTool,
      Tools::ListInsightsTool,
      Tools::ReadInsightTool,
      Tools::ReadInsightRunTranscriptTool,
      Tools::ListRecentWorkflowsTool
    ].freeze

    # A chat can read insights and retire one it has superseded with real
    # work, but never author or edit one -- authoring belongs to the insight
    # run, so a chat agent cannot manufacture its own backlog.
    CHAT_TOOL_CLASSES = [
      Tools::ListInsightsTool,
      Tools::ReadInsightTool,
      Tools::RetireInsightTool
    ].freeze

    def self.available_for?(_repository) = AgentInsights.enabled?

    def self.tool_definitions(context: nil)
      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.definition_for(klass)
      {
        name: klass.tool_name,
        description: klass.description_value,
        input_schema: klass.input_schema_value.to_h
      }
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      unless klass
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown Agent Insights tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[AgentInsights::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
