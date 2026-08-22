class ChatTitleJob < ApplicationJob
  queue_as :low_priority_maintenance
  discard_on ActiveRecord::RecordNotFound

  class << self
    attr_accessor :agent_runner
  end

  def perform(chat_session_id, user_message_id)
    chat_session = ChatSession.includes(:user, :attached_repositories).find(chat_session_id)
    return if chat_session.title.present? && !chat_session.title_auto_fallback?

    user_message = chat_session.messages.where(role: "user").find(user_message_id)
    chat_provider = chat_session.pin_chat_provider!(broadcast: false)
    generated = ChatTitleGenerator.new(
      chat_session: chat_session,
      message_text: user_message.content["text"],
      chat_provider: chat_provider,
      runner: self.class.agent_runner
    ).call

    if generated.success?
      chat_session.update!(title: generated.title, title_auto_fallback: false)
    else
      chat_session.update!(title: fallback_title(chat_session), title_auto_fallback: true)
    end
  end

  private

  def fallback_title(chat_session)
    ChatSession.fallback_title_for(chat_session.repository).presence || "New chat"
  end
end
