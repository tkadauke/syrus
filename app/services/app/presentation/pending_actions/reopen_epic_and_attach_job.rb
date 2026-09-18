module App
  module Presentation
    module PendingActions
      class ReopenEpicAndAttachJob < Base
        action_key "reopen_epic_and_attach_job"

        def label
          "Reopen Epic ##{payload['epic_id']} and attach #{job_slug}"
        end
      end
    end
  end
end
