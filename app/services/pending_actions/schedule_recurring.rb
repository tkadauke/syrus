module PendingActions
  class ScheduleRecurring < Base
    action_key "schedule_recurring"

    def execute
      ScheduledTask.create!(
        user: user,
        repository: repository,
        kind: "cron",
        name: payload.fetch("label"),
        schedule_input: payload.fetch("schedule_input", payload["cron_expression"]),
        cron_expression: payload["cron_expression"],
        schedule_expression: payload["schedule_expression"],
        schedule_timezone: payload["schedule_timezone"],
        prompt: payload.fetch("prompt")
      )
    end

    def validate_payload(errors)
      errors.add(:payload, "schedule_input is required") if payload["schedule_input"].to_s.strip.blank? && payload["cron_expression"].to_s.strip.blank?
      errors.add(:payload, "label is required") if payload["label"].to_s.strip.blank?
      errors.add(:payload, "prompt is required") if payload["prompt"].to_s.strip.blank?
    end

    def action_detail
      [ "label: #{payload["label"]}", payload["schedule_explanation"].presence ].compact.join("\n")
    end
  end
end
