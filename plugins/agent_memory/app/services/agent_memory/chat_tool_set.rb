module AgentMemory
  class ChatToolSet < McpToolSet
    # Reading another user's memory audit trail is an admin capability, so it
    # is advertised only to admin chats rather than merely refused at call
    # time -- a tool a chat can see is a tool it will try.
    ADMIN_TOOL_CLASSES = { essential: [ Tools::AdminReadMemoryAuditHistoryTool ].freeze }.freeze

    def self.available_for?(_chat_session, tier:)
      AgentMemory.enabled? && CHAT_TOOL_CLASSES.key?(tier.to_sym)
    end

    # `tier: nil` is the registry's name-uniqueness probe, which wants every
    # tool this set can ever advertise, admin tools included.
    def self.tool_definitions(tier:, chat_session: nil)
      return handler_classes.map { |klass| definition_for(klass) } if tier.nil?

      classes = CHAT_TOOL_CLASSES.fetch(tier.to_sym, [])
      classes += ADMIN_TOOL_CLASSES.fetch(tier.to_sym, []) if chat_session&.user&.admin?
      classes.map { |klass| definition_for(klass) }
    end

    def self.handler_classes = (CHAT_TOOL_CLASSES.values + ADMIN_TOOL_CLASSES.values).flatten
  end
end
