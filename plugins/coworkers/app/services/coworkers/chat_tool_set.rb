module Coworkers
  class ChatToolSet
    TOOLS = [ McpTools::ProposeCoworkerTool, McpTools::ProposeGrantEscalationTool ].freeze

    def self.available_for?(chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :deferred && !Coworkers::Chat.exists?(chat_session_id: chat_session.id)
    end

    def self.tool_definitions(tier:)
      TOOLS.map { |tool| { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h } }
    end

    def handle(tool_name, params, server_context)
      tool = TOOLS.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown coworker tool: #{tool_name.inspect}") unless tool
      tool.call(**(params || {}).symbolize_keys, server_context: server_context)
    end
  end
end
