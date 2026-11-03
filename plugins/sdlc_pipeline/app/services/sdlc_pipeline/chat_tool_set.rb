require "mcp"

module SdlcPipeline
  class ChatToolSet
    TOOL_CLASSES = [ ShowPipelineTool ].freeze

    def self.available_for?(_chat_session, tier:)
      SdlcPipeline.enabled? && tier.to_sym == :deferred
    end

    def self.tool_definitions(tier:)
      TOOL_CLASSES.map do |klass|
        { name: klass.tool_name, description: klass.description_value, input_schema: klass.input_schema_value.to_h }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown SDLC Pipeline tool: #{tool_name.inspect}") unless klass

      klass.call(**(params || {}).symbolize_keys, server_context: server_context)
    end
  end
end
