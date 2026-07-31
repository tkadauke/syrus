class ScheduledChatMessageFireJob < ApplicationJob
  queue_as :chat

  def perform(scheduled_message_id)
    chat_message = nil
    scheduled_message = ApplicationRecord.transaction do
      message = ScheduledChatMessage.lock.where(sent_at: nil).find_by(id: scheduled_message_id)
      next unless message

      chat = ChatSession.lock.find(message.chat_session_id)
      chat_message = chat.messages.create!(
        role: "user",
        content: {
          "text" => message.body,
          "requested_by" => "scheduled_message",
          "scheduled_message_id" => message.id
        }
      )
      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence
      )
      message.update!(sent_at: Time.current)
      message
    end
    return unless scheduled_message

    ChatTurnJob.perform_later(scheduled_message.chat_session_id, chat_message.id)
  end
end
