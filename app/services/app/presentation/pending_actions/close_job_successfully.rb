module App
  module Presentation
    module PendingActions
      class CloseJobSuccessfully < Base
        action_key "close_job_successfully"

        def label
          "Close #{job_slug} as #{payload['closure_reason']}"
        end

        def detail
          payload["comment"].presence
        end
      end
    end
  end
end
