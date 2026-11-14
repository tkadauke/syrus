module AgentInsights
  class ChatToolSet < McpToolSet
    TOOL_CLASSES = McpToolSet::CHAT_TOOL_CLASSES
    COWORKER_TOOL_CLASSES = [
      Tools::ListInsightsTool,
      Tools::ReadInsightTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      AgentInsights.enabled? && tier.to_sym == :deferred
    end

    def self.available_for_coworker?(_chat_session, tier:)
      AgentInsights.enabled? && tier.to_sym == :deferred
    end

    # `tier: nil` is the registry's inventory probe and must keep returning
    # the ordinary chat inventory used by compatibility validation.
    def self.tool_definitions(tier:, chat_session: nil)
      if coworker_chat?(chat_session)
        return [] unless tier.to_sym == :deferred

        return COWORKER_TOOL_CLASSES.map do |klass|
          definition_for(klass).merge(coworker_safe: true, ungated: true)
        end
      end

      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.handler_classes(context: nil) = TOOL_CLASSES

    def self.coworker_chat?(chat_session)
      chat_session && McpToolContext.from_chat_session(chat_session).role == AgentRole::COWORKER_CHAT
    end
  end
end
