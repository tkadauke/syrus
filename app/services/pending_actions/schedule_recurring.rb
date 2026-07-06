module PendingActions
  class ScheduleRecurring < Base
    action_key "schedule_recurring"

    def execute
      ScheduledTask.create!(
        user: user,
        repository: repository,
        kind: "cron",
        name: payload.fetch("label"),
        cron_expression: payload.fetch("cron_expression"),
        prompt: payload.fetch("prompt")
      )
    end

    def validate_payload(errors)
      errors.add(:payload, "cron_expression is required") if payload["cron_expression"].to_s.strip.blank?
      errors.add(:payload, "label is required") if payload["label"].to_s.strip.blank?
      errors.add(:payload, "prompt is required") if payload["prompt"].to_s.strip.blank?
    end

    def action_detail
      "label: #{payload["label"]}"
    end
  end
end
