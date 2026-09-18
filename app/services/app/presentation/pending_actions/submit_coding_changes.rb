module App
  module Presentation
    module PendingActions
      class SubmitCodingChanges < Base
        action_key "submit_coding_changes"

        def label
          payload["title"].presence || action.action_type.to_s.humanize
        end

        def detail
          payload["description"].presence
        end
      end
    end
  end
end
