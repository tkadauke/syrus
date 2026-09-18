module App
  module Presentation
    module PendingActions
      class CancelStaleWork < Base
        action_key "cancel_stale_work"

        def label
          "Cancel stale work for #{job_slug}"
        end

        def detail
          [
            Array(payload["workflow_ids"]).presence&.then { |ids| "Workflows: #{ids.join(', ')}" },
            Array(payload["run_ids"]).presence&.then { |ids| "Runs: #{ids.join(', ')}" }
          ].compact.join("\n").presence
        end
      end
    end
  end
end
