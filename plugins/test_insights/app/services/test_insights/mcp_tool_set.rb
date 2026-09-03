require "mcp"

module TestInsights
  # Read-only Test Insights access for workflow agents: bounded flaky, failing,
  # and slow-test investigation without scraping transcripts.
  class McpToolSet
    TOOL_CLASSES = [
      Tools::ListRepositoryTestInsightsTool,
      Tools::ReadTestInsightTool,
      Tools::ReadJobTestResultsTool,
      Tools::ReadRunTestResultsTool,
      Tools::CompareTestRuntimeTool
    ].freeze

    def self.available_for?(_repository) = TestInsights.enabled?

    def self.tool_definitions(context: nil)
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
      unless klass
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown Test Insights tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[TestInsights::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
