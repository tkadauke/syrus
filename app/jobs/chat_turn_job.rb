class ChatTurnJob < ApplicationJob
  queue_as :runs
  limits_concurrency to: 1, key: ->(chat_session_id, *) {
    chat_session = ChatSession.find(chat_session_id)
    "chat:#{chat_session.repository_id}"
  }

  def perform(chat_session_id, user_message_id)
    raise NotImplementedError, "ChatTurnJob streaming is implemented by the chat agent pipeline"
  end
end
