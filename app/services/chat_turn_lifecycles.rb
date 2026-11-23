class ChatTurnLifecycles
  class Default
    def self.applies_to?(**) = true

    def initialize(chat_session:, user_message:)
      @chat_session = chat_session
      @user_message = user_message
    end

    def admission = {}
    def context = @chat_session
    def isolated_workspace? = false
    def synchronize(&block) = block.call
  end

  def self.for(chat_session:, user_message:)
    provider = Syrus::Plugin::ChatIntegration.contributions(:turn_lifecycles).find do |candidate|
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :chat_turn_lifecycle, provider: candidate, operation: :applies_to,
        on_decline: false
      ) { candidate.applies_to?(chat_session:, user_message:) })
    end
    return Default.new(chat_session:, user_message:) unless provider

    lifecycle = Syrus::PluginInvocation.call(
      extension_point: :chat_turn_lifecycle, provider:, operation: :initialize, on_decline: nil
    ) { provider.new(chat_session:, user_message:) }
    Syrus::PluginInvocation.value(lifecycle) || Default.new(chat_session:, user_message:)
  end
end
