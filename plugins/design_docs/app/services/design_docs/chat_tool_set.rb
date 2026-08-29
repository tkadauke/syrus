require "mcp"

module DesignDocs
  class ChatToolSet
    extend McpToolSupport

    TOOL_CLASSES = [
      ListDesignDocsTool,
      ReadDesignDocTool,
      ProposeDesignDocTool,
      CommentOnDesignDocTool,
      SuggestDesignDocChangeTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      %i[essential deferred].include?(tier.to_sym)
    end

    def self.tool_definitions(tier:)
      tool_definitions_for(TOOL_CLASSES)
    end

    def handle(tool_name, params, server_context)
      chat_session = server_context && server_context[:chat_session]
      return self.class.error_response("No chat session available in this context.") unless chat_session

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return self.class.error_response("Unknown design docs tool: #{tool_name.inspect}") unless klass

      klass.call(chat_session: chat_session, server_context: server_context, **self.class.symbolize(params))
    rescue Pundit::NotAuthorizedError
      self.class.error_response("not authorized for that design doc")
    rescue ActiveRecord::RecordInvalid => e
      self.class.error_response(e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound => e
      self.class.error_response(e.message)
    rescue StandardError => e
      Rails.logger.error("[DesignDocs::ChatToolSet] #{e.class}: #{e.message}")
      self.class.error_response("#{e.class}: #{e.message}")
    end
  end
end
