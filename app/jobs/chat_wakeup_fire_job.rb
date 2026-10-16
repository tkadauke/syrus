class ChatWakeupFireJob < ApplicationJob
  queue_as :control_plane

  def perform(wakeup_id)
    chat_session_id = ChatWakeup.where(id: wakeup_id).pick(:chat_session_id)
    return unless chat_session_id

    ChatSession.transaction do
      chat_session = ChatSession.lock.find_by(id: chat_session_id)
      return unless chat_session

      wakeup = ChatWakeup.pending.lock.find_by(id: wakeup_id)
      return unless wakeup
      if chat_session.deleted?
        wakeup.update!(state: "cancelled")
        return
      end

      message = ChatSession::WakeupTurn.new(wakeup).run
      wakeup.update!(state: message ? "fired" : "cancelled")
    end
  end
end
