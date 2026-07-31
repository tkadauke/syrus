class PollScheduledChatMessagesJob < ApplicationJob
  queue_as :default

  def perform
    ScheduledChatMessage.due.find_each do |scheduled_message|
      ScheduledChatMessageFireJob.perform_later(scheduled_message.id)
    end
  end
end
