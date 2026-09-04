module AgentInsights
  class ChatToolSet < McpToolSet
    TOOL_CLASSES = McpToolSet::CHAT_TOOL_CLASSES

    def self.available_for?(_chat_session, tier:)
      AgentInsights.enabled? && tier.to_sym == :deferred
    end

    def self.tool_definitions(tier:)
      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end
  end
end
