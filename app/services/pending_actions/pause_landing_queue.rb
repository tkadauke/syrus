module PendingActions
  class PauseLandingQueue < Base
    action_key "pause_landing_queue"

    def execute
      user.update!(landing_paused: true)
      nil
    end

    def execution_label
      "Pausing landing queue..."
    end
  end
end
