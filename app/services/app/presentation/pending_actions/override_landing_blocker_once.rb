module App
  module Presentation
    module PendingActions
      class OverrideLandingBlockerOnce < Base
        action_key "override_landing_blocker_once"

        def label
          "Override #{payload['blocker_key']} once for #{job_slug}"
        end
      end
    end
  end
end
