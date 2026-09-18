module App
  module Presentation
    module PendingActions
      class MarkCiRepairNoop < Base
        action_key "mark_ci_repair_noop"

        def label
          "Mark CI repair as no-op for #{job_slug}"
        end

        def detail
          "Workflow: ##{payload['workflow_id']}"
        end
      end
    end
  end
end
