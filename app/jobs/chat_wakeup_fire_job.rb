class ChatWakeupFireJob < ApplicationJob
  queue_as :control_plane

  def perform(wakeup_id)
    ChatWakeup.transaction do
      wakeup = ChatWakeup.pending.lock.find_by(id: wakeup_id)
      return unless wakeup

      ChatSession::WakeupTurn.new(wakeup).run
      wakeup.update!(state: "fired")
    end
  end
end
