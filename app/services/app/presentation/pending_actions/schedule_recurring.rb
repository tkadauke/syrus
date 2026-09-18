module App
  module Presentation
    module PendingActions
      # action_type-based (not action-based): scheduled reminders/recurring
      # tasks proposed by the chat agent rather than admin/job controls.
      class ScheduleRecurring < Base
        action_key "schedule_recurring"

        def label
          payload["label"].presence || action.action_type.to_s.humanize
        end

        def detail
          [
            [ payload["label"], payload["schedule_explanation"] || payload["schedule_input"] || payload["cron_expression"] ].compact_blank.join(" — ").presence,
            payload["prompt"].presence
          ].compact.join("\n\n").presence
        end
      end
    end
  end
end
