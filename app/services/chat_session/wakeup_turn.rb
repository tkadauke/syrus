class ChatSession::WakeupTurn
  def initialize(wakeup)
    @wakeup = wakeup
    @chat_session = wakeup.chat_session
  end

  def run
    message = nil

    ApplicationRecord.transaction do
      locked_chat = ChatSession.lock.find(@chat_session.id)
      content = {
        "text" => @wakeup.prompt,
        "requested_by" => "wakeup",
        "wakeup_id" => @wakeup.id
      }.merge(@wakeup.metadata.presence || {})

      message = locked_chat.messages.create!(
        role: "user",
        content: content
      )
      locked_chat.update!(
        last_message_at: Time.current,
        title: locked_chat.title.presence
      )
    end

    ChatTurnJob.perform_later(@chat_session.id, message.id)
    message
  end
end
