module Mail
  class ChatToolSet
    TOOLS = [ SearchTool, ReadMessageTool ].freeze
    def self.available_for?(_chat, tier:) = Mail.enabled? && tier.to_sym == :deferred
    def self.tool_definitions(tier:)
      TOOLS.map { |tool| { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h,
        capability_descriptor: PermissionProvider.capability_descriptor(PermissionProvider::OPERATIONS.fetch(tool.tool_name)) } }
    end
    def handle(name, params, context) = TOOLS.find { |tool| tool.tool_name == name.to_s }.call(**params.symbolize_keys, server_context: context)
  end
end
