class LandingQueueProcessorJob < ApplicationJob
  queue_as :control_plane

  limits_concurrency to: 1, key: -> { "landing_queue_processor" }

  def perform
    return if AppSetting.polling_paused?

    LandingQueueProcessor.call
  end
end
