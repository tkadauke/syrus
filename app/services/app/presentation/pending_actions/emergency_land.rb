module App
  module Presentation
    module PendingActions
      class EmergencyLand < Base
        SKIPS_NOTICE = "Skips Syrus graders, adversarial review, and visual review; merges the PR directly through GitHub after confirmation. GitHub branch protection still applies.".freeze

        action_key "emergency_land"

        def label
          "Emergency land #{job_slug}"
        end

        def detail
          [
            payload["branch_name"].presence&.then { |branch| "Branch: #{branch}" },
            SKIPS_NOTICE
          ].compact.join("\n")
        end
      end
    end
  end
end
