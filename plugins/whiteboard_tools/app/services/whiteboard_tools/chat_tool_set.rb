require "mcp"

module WhiteboardTools
  # Chat MCP tool set for the whiteboard: draw/move/delete/read/update the
  # live Excalidraw scene, plus save/clear/load named snapshots. Each tool
  # (see the individual *_tool.rb files in this directory) is its own
  # MCP::Tool class; this set just aggregates them and dispatches by name,
  # mirroring PreviewTools::ChatToolSet / AdminMysql::ChatToolSet.
  class ChatToolSet
    TOOL_CLASSES = [
      ReadSceneTool,
      DrawShapeTool,
      DrawTextTool,
      DrawLineTool,
      DrawArrowTool,
      DrawFreedrawTool,
      DrawFrameTool,
      DrawEmbedTool,
      DrawImageTool,
      MoveElementTool,
      DeleteElementTool,
      UpdateSceneTool,
      SaveCanvasTool,
      ClearCanvasTool,
      LoadCanvasTool
    ].freeze

    # Same tier the individual tools used to declare (tier: :deferred, no
    # feature_flag / required_roles) -- available in every chat once the
    # deferred tool tier is loaded.
    def self.available_for?(_chat_session, tier:)
      tier.to_sym == :deferred
    end

    # available_for? is the tier gate (deferred only, matching the tools'
    # former tier: :deferred registration); tier isn't otherwise consulted
    # here so a nil tier (used by Syrus::PluginRegistry's cross-plugin tool
    # name uniqueness check) still returns the full definition list.
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
      return Mcp::Tools.invalid("Unknown whiteboard tool: #{tool_name.inspect}") unless klass

      klass.call(**normalize_params(params), server_context: server_context)
    end

    private

    def normalize_params(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
