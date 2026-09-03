require "mcp"

module SpendingInsights
  # Exposes the spending rollup to chat agents. Deferred tier: cost questions
  # are occasional, so the tool should not take up an essential-tier slot.
  class ChatToolSet
    TOOL_CLASSES = [ GetSpendingTool ].freeze

    def self.available_for?(_chat_session, tier:)
      SpendingInsights.enabled? && tier.to_sym == :deferred
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
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown Spending Insights tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[SpendingInsights::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
