module Coworkers
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    TOOL_CLASSES = [ MessageCoworkerTool ].freeze

    def self.available_for?(_chat_session, tier:)
      false
    end

    def self.available_for_coworker?(_chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :essential
    end

    def self.tool_definitions(tier:)
      return [] unless tier.nil? || tier.to_sym == :essential

      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h,
          coworker_safe: true,
          capability: "coworker.message",
          mutation: true
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown coworker tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
