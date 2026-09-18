module App
  module Presentation
    module PendingActions
      class RerunCiRepair < Base
        action_key "rerun_ci_repair"

        def label
          "Re-run CI repair for #{job_slug}"
        end

        def detail
          payload["instructions"].presence
        end
      end
    end
  end
end
