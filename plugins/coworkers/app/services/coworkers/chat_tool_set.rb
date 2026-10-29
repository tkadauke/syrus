module Coworkers
  class ChatToolSet
    TOOL = McpTools::ProposeCoworkerTool

    def self.available_for?(chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :deferred && !Coworkers::Chat.exists?(chat_session_id: chat_session.id)
    end

    def self.tool_definitions(tier:)
      [ { name: TOOL.tool_name, description: TOOL.description_value, input_schema: TOOL.input_schema_value.to_h } ]
    end

    def handle(tool_name, params, server_context)
      return Mcp::Tools.invalid("Unknown coworker tool: #{tool_name.inspect}") unless tool_name.to_s == TOOL.tool_name
      TOOL.call(**(params || {}).symbolize_keys, server_context: server_context)
    end
  end
end
