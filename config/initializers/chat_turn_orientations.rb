Rails.application.config.after_initialize do
  Syrus::PluginRegistry.register_direct(:chat_turn_orientation, ChatSession::CrossChatTurnOrientation)
end
