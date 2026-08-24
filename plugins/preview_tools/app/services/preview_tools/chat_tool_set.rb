require "mcp"

module PreviewTools
  # Planning-mode-only chat MCP tools. Planning mode has no Write/Edit tools
  # at all (Prompts::ChatSystem) so an agent that wants to build an HTML/CSS/JS
  # mockup or interactive widget page needs a narrow, jailed alternative:
  # write/edit that can only touch a PreviewPanel's own scratch directory,
  # plus show_preview/close_preview to publish that directory to the panel
  # the operator sees in the chat sidebar.
  #
  # Both "quick interactive widget" and "freeform mockup" go through the
  # same show_preview call -- the only difference is what the agent wrote
  # into the scratch directory (a CDN <script>/<link> tag vs. hand-authored
  # layout).
  #
  # Each tool (see ToolSupport and the individual *_tool.rb files in this
  # directory) is its own MCP::Tool class; this set just aggregates them and
  # dispatches by name instead of a growing case statement.
  class ChatToolSet
    extend ToolSupport

    TOOL_CLASSES = [
      WritePreviewFileTool,
      EditPreviewFileTool,
      ShowPreviewTool,
      ClosePreviewTool
    ].freeze

    def self.available_for?(chat_session, tier:)
      !chat_session.coding? && !chat_session.local? && %i[essential deferred].include?(tier.to_sym)
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
      return self.class.error_response("No chat session available in this context.") unless chat_session

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return self.class.error_response("Unknown preview tool: #{tool_name.inspect}") unless klass

      klass.call(chat_session: chat_session, server_context: server_context, **self.class.symbolize(params))
    rescue ScratchDirectory::InvalidPath => e
      self.class.error_response(e.message)
    rescue StandardError => e
      Rails.logger.error("[PreviewTools::ChatToolSet] #{e.class}: #{e.message}")
      self.class.error_response("#{e.class}: #{e.message}")
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
