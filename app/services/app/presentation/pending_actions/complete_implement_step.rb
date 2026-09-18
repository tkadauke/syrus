module App
  module Presentation
    module PendingActions
      class CompleteImplementStep < Base
        action_key "complete_implement_step"

        def label
          "Hand off #{job_slug}"
        end

        def detail
          payload["branch_name"].presence&.then { |branch| "Branch: #{branch}" }
        end
      end
    end
  end
end
