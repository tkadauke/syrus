module PendingActions
  class ResumeLandingQueue < Base
    action_key "resume_landing_queue"

    def execute
      user.update!(landing_paused: false)
      LandingQueueProcessorJob.perform_later
      nil
    end
  end
end
