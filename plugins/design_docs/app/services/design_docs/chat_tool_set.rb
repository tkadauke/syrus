module DesignDocs
  class ChatToolSet
    TOOL_CLASSES = [
      ListDesignDocsTool,
      ReadDesignDocTool,
      ProposeDesignDocTool,
      CommentOnDesignDocTool,
      SuggestDesignDocChangeTool
    ].freeze

    def self.available_for?(chat_session, tier:)
      DesignDocs.enabled? && chat_session.present? && tier.to_sym == :deferred
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
      return Mcp::Tools.invalid("Unknown design docs tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
