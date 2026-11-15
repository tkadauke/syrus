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
    provider = Syrus::PluginRegistry.providers_for(:chat_turn_lifecycle).find do |candidate|
      candidate.applies_to?(chat_session:, user_message:)
    end
    (provider || Default).new(chat_session:, user_message:)
  end
end
