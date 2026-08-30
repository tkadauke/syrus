class ChatCodingRelayRefreshJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  def perform(chat_session_id)
    chat_session = ChatSession.find(chat_session_id)
    repository = chat_session.repository
    return unless repository

    ChatWorkspace.refresh_relay_credentials!(chat_session, repository)
  end
end
