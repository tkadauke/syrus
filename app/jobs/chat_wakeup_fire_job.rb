class ChatWakeupFireJob < ApplicationJob
  queue_as :control_plane

  def perform(wakeup_id)
    ChatWakeup.transaction do
      wakeup = ChatWakeup.pending.lock.find_by(id: wakeup_id)
      return unless wakeup
      if wakeup.chat_session.deleted?
        wakeup.update!(state: "cancelled")
        return
      end

      message = ChatSession::WakeupTurn.new(wakeup).run
      wakeup.update!(state: message ? "fired" : "cancelled")
    end
  end
end
