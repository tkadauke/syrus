class PollScheduledChatMessagesJob < ApplicationJob
  queue_as :control_plane

  def perform
    now = Time.current
    ScheduledChatMessage.due(now).recoverable(now).find_each do |scheduled_message|
      scheduled_message.claim_and_enqueue_fire_job(now: now)
    end
  end
end
