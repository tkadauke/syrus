module App
  module Presentation
    module PendingActions
      class ReenqueueWork < Base
        action_key "reenqueue_work"

        def label
          "Re-enqueue work for #{job_slug}"
        end

        def detail
          [
            payload["workflow_id"].presence&.then { |id| "Workflow: ##{id}" },
            payload["run_id"].presence&.then { |id| "Run: ##{id}" }
          ].compact.join(", ").presence
        end
      end
    end
  end
end
