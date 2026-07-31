class ChatTitleJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  class << self
    attr_accessor :agent_runner
  end

  def perform(chat_session_id, user_message_id)
    chat_session = ChatSession.includes(:user, :attached_repositories).find(chat_session_id)
    return if chat_session.title.present?

    user_message = chat_session.messages.where(role: "user").find(user_message_id)
    chat_provider = chat_session.pin_chat_provider!(broadcast: false)
    generated = ChatTitleGenerator.new(
      chat_session: chat_session,
      message_text: user_message.content["text"],
      chat_provider: chat_provider,
      runner: self.class.agent_runner
    ).call

    chat_session.update!(title: generated.success? ? generated.title : fallback_title(chat_session))
  end

  private

  def fallback_title(chat_session)
    ChatSession.fallback_title_for(chat_session.repository).presence || "New chat"
  end
end
