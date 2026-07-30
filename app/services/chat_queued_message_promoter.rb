class ChatQueuedMessagePromoter
  def self.deliver_one_if_idle!(chat_session)
    new(chat_session).deliver_one_if_idle!
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def deliver_one_if_idle!
    user_message = nil

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      return false if chat.stop_requested_at?
      return false if chat.turn_in_flight?
      return false if chat.agent_busy?

      queued_message = chat.queued_messages.first
      return false unless queued_message

      user_message = chat.messages.create!(role: "user", content: queued_message.content)
      queued_message.update!(delivered_at: Time.current)
      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence
      )
      chat.pin_chat_provider!
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id)
    true
  end
end
