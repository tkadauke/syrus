class ScheduledChatMessageFireJob < ApplicationJob
  queue_as :chat

  def perform(scheduled_message_id)
    chat_message = nil
    turn_triggered = false
    scheduled_message = ApplicationRecord.transaction do
      message = ScheduledChatMessage.lock.where(sent_at: nil).find_by(id: scheduled_message_id)
      next unless message

      chat = ChatSession.lock.find(message.chat_session_id)
      content = {
        "text" => message.body,
        "requested_by" => "scheduled_message",
        "scheduled_message_id" => message.id
      }

      if chat.turn_in_flight? || chat.agent_busy?
        chat.chat_queued_messages.create!(
          content: content.merge(ChatQueuedMessage::INTERNAL_SENDER_USER_ID_KEY => message.user_id)
        )
        chat.touch
      else
        turn_triggered = chat.should_trigger_agent?(message.body)
        chat_message = chat.messages.create!(
          role: "user",
          sender_user: message.user,
          content: content,
          skip_turn_trigger: !turn_triggered
        )
        chat.update!(last_message_at: Time.current)
      end

      message.update!(sent_at: Time.current)
      message
    end
    return unless scheduled_message

    ChatTurnJob.perform_later(scheduled_message.chat_session_id, chat_message.id) if turn_triggered
  end
end
