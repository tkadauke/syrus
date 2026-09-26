Rails.application.config.after_initialize do
  Syrus::PluginRegistry.register(:chat_turn_orientation, ChatSession::CrossChatTurnOrientation)
end
