class ChatTurnJob < ApplicationJob
  CONCURRENCY_GROUP = "repository_chat"

  queue_as :runs
  limits_concurrency to: 1, group: CONCURRENCY_GROUP, key: ->(chat_session_id, *) {
    chat_session = ChatSession.find(chat_session_id)
    "chat:#{chat_session.repository_id}"
  }

  def perform(chat_session_id, user_message_id)
    raise NotImplementedError, "ChatTurnJob streaming is implemented by the chat agent pipeline"
  end
end
