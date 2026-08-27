require "mcp"

module ThemingTools
  # Chat MCP tool set for theming: currently just preview_theme (see its
  # class for the design). Mirrors WhiteboardTools::ChatToolSet /
  # MysqlDbBrowser::ChatToolSet's aggregate-and-dispatch-by-name shape so a
  # future install_theme / CRUD tools job can drop new tool classes into
  # TOOL_CLASSES without touching this dispatch logic.
  class ChatToolSet
    TOOL_CLASSES = [
      PreviewThemeTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      tier.to_sym == :deferred
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
      chat_session = server_context && server_context[:chat_session]
      return Mcp::Tools.invalid("No chat session available in this context.") unless chat_session

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown theming tool: #{tool_name.inspect}") unless klass

      klass.call(**normalize_params(params), server_context: server_context)
    end

    private

    def normalize_params(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
