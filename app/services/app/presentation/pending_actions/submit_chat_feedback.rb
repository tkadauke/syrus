module App
  module Presentation
    module PendingActions
      class SubmitChatFeedback < Base
        action_key "submit_chat_feedback"

        def label
          "Submit feedback on #{job_slug}"
        end

        def detail
          payload["feedback"].presence
        end
      end
    end
  end
end
