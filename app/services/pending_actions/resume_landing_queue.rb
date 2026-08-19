module PendingActions
  class ResumeLandingQueue < Base
    action_key "resume_landing_queue"

    def execute
      progress!("Resuming landing queue...")
      user.update!(landing_paused: false)
      progress!("Queueing landing processor wakeup...")
      LandingQueueProcessorJob.perform_later
      nil
    end

    def execution_label
      "Resuming landing queue..."
    end
  end
end
