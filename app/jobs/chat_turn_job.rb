class ChatTurnJob < ApplicationJob
  queue_as :runs

  def perform(chat_session_id, user_message_id)
    raise NotImplementedError, "ChatTurnJob streaming is implemented by the chat agent pipeline"
  end
end
