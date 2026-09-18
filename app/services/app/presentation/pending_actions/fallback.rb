module App
  module Presentation
    module PendingActions
      # Not bound to any action_key -- returned by .for whenever no
      # dedicated presenter is registered for the action's key.
      class Fallback < Base
        def label
          payload["label"].presence || action.action_type.to_s.humanize
        end
      end
    end
  end
end
