module AgentInsights
  class ChatToolSet < McpToolSet
    TOOL_CLASSES = McpToolSet::CHAT_TOOL_CLASSES

    def self.available_for?(_chat_session, tier:)
      AgentInsights.enabled? && tier.to_sym == :deferred
    end

    # `tier: nil` is the registry's inventory probe and must keep returning
    # the ordinary chat inventory used by compatibility validation.
    def self.tool_definitions(tier:, chat_session: nil)
      return [] unless tier.nil? || tier.to_sym == :deferred

      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.handler_classes(context: nil) = TOOL_CLASSES
  end
end
