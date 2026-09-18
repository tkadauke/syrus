module App
  module Presentation
    module PendingActions
      class ForceStateTransition < Base
        action_key "force_state_transition"

        def label
          "Force #{payload['event']} on #{job_slug}"
        end

        def detail
          "Event: #{payload['event']}"
        end
      end
    end
  end
end
