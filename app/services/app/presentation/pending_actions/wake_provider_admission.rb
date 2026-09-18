module App
  module Presentation
    module PendingActions
      class WakeProviderAdmission < Base
        action_key "wake_provider_admission"

        def label
          payload["user_id"].present? ? "Wake #{payload['provider']} admission for user ##{payload['user_id']}" : "Wake #{payload['provider']} admission"
        end
      end
    end
  end
end
