module App
  module Presentation
    module PendingActions
      class ReconcileJobState < Base
        action_key "reconcile_job_state"

        def label
          "Reconcile state for #{job_slug} (#{payload['mode']})"
        end

        def detail
          "Mode: #{payload['mode']}"
        end
      end
    end
  end
end
