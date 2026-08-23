require "mcp"

module AdminMysql
  class ChatToolSet
    TOOL_CLASSES = [
      StatusTool,
      KillQueryTool
    ].freeze

    def self.available_for?(chat_session, tier:)
      chat_session.user.admin? && AdminMysql.mysql? && %i[ essential deferred ].include?(tier.to_sym)
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
      return MCP::Tool::Response.new([ { type: "text", text: "Unknown Admin MySQL tool: #{tool_name.inspect}" } ], error: true) unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[AdminMysql::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
