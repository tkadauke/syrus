require "mcp"

module VideoWalkthroughs
  # The three tools the walkthrough handoff runs on. They used to sit in core's
  # McpToolRegistry behind a `feature_flag: :video_walkthroughs` filter that
  # McpToolPolicy applied by hand; the plugin's enabled state is that filter
  # now, so the tools simply are not advertised when it is off.
  #
  # All three are read-only: they return an analysis, re-analyze a range of an
  # already-uploaded video, or extract a still. None of them mutates anything,
  # which is why they are safe in every chat mode.
  class ChatToolSet
    TOOL_CLASSES = [
      GetWalkthroughAnalysisTool,
      AnalyzeWalkthroughSegmentTool,
      ReadWalkthroughFrameTool
    ].freeze

    # Deferred rather than essential: a chat with no walkthrough in it should
    # not spend prompt budget on three tool schemas it will never call.
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
      return self.class.error_response("No chat session available in this context.") unless server_context && server_context[:chat_session]

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return self.class.error_response("Unknown walkthrough tool: #{tool_name.inspect}") unless klass

      klass.call(server_context: server_context, **self.class.symbolize(params))
    rescue StandardError => e
      Rails.logger.error("[VideoWalkthroughs::ChatToolSet] #{e.class}: #{e.message}")
      self.class.error_response("#{e.class}: #{e.message}")
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def self.error_response(message)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{message}" } ], error: true)
    end
  end
end
