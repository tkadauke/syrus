class Coworkers::SpawnChat
  def self.call(...) = new(...).call

  def initialize(coworker:, prompt:, title: nil, server_context:)
    @coworker = coworker
    @prompt = prompt.to_s.strip
    @title = title.to_s.strip.presence
    @server_context = server_context
  end

  def call
    chat = nil
    message = nil
    ApplicationRecord.transaction do
      chat = ChatSession.create!(user: @coworker.owner_user, repository: @coworker.workspace_repository,
        title: @title || @coworker.name, last_message_at: Time.current, conversation_kind: "direct", **@coworker.chat_configuration)
      Coworkers::Chat.create!(coworker: @coworker, chat_session: chat, role: "side")
      message = chat.messages.create!(role: "user", content: { "text" => @prompt }, sender_user_id: @coworker.owner_user_id,
        skip_turn_trigger: false)
      chat.pin_chat_provider!(chat.chat_provider)
    end
    ChatSessions::Creator.enqueue_turn(chat, message)
    chat
  end
end
