class ChatQueuedMessagePromoter
  def self.deliver_one_if_idle!(chat_session)
    new(chat_session).deliver_one_if_idle!
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def deliver_one_if_idle!
    user_message = nil
    turn_triggered = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      return false if chat.stop_requested_at?
      return false if chat.turn_in_flight?
      return false if chat.agent_busy?

      queued_message = chat.queued_messages.first
      return false unless queued_message

      turn_triggered = turn_triggered?(chat, queued_message)
      role = message_role(queued_message)
      user_message = chat.messages.create!(role: role, content: queued_message.content, skip_turn_trigger: !turn_triggered)
      chat.update_columns(turn_in_flight: true, last_message_at: user_message.created_at || Time.current) if role == "system" && turn_triggered
      queued_message.update!(delivered_at: Time.current)
      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence
      )
      chat.pin_chat_provider!
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id) if turn_triggered
    true
  end

  private

  def turn_triggered?(chat, queued_message)
    return true if goal_continuation?(queued_message)

    chat.should_trigger_agent?(queued_message.text)
  end

  def message_role(queued_message)
    goal_continuation?(queued_message) ? "system" : "user"
  end

  def goal_continuation?(queued_message)
    queued_message.content.is_a?(Hash) && queued_message.content["goal_continuation"] == true
  end
end
