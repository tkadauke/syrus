require "mcp"

module TestInsights
  # Read-only Test Insights access for chat agents, deferred tier: a chat
  # rarely needs test history, but when it does, scraping transcripts is worse
  # than a bounded query.
  class ChatToolSet
    TOOL_CLASSES = [
      Tools::ListRepositoryTestInsightsTool,
      Tools::ReadTestInsightTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      TestInsights.enabled? && tier.to_sym == :deferred
    end

    def self.tool_definitions(tier:)
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
      Rails.logger.error("[TestInsights::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
