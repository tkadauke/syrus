module PendingActions
  class ScheduleRecurring < Base
    action_key "schedule_recurring"

    def execute
      progress!("Creating scheduled task...")
      ScheduledTasks::Task.create!(
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

    # Core asks the action what to say, rather than matching on the model.
    def self.confirmed_notice(record)
      return nil unless record.is_a?(ScheduledTasks::Task)

      "Scheduled task created: #{record.name}."
    end

    def execution_label
      "Creating scheduled task..."
    end

    def validate_payload(errors)
      errors.add(:payload, "schedule_input is required") if payload["schedule_input"].to_s.strip.blank? && payload["cron_expression"].to_s.strip.blank?
      errors.add(:payload, "label is required") if payload["label"].to_s.strip.blank?
      errors.add(:payload, "prompt is required") if payload["prompt"].to_s.strip.blank?
    end

    def action_detail
      [ "label: #{payload["label"]}", payload["schedule_explanation"].presence ].compact.join("\n")
    end

    def presentation_label
      payload["label"].presence || action.action_type.to_s.humanize
    end

    def presentation_detail
      [
        [ payload["label"], payload["schedule_explanation"] || payload["schedule_input"] || payload["cron_expression"] ].compact_blank.join(" — ").presence,
        payload["prompt"].presence
      ].compact.join("\n\n").presence
    end
  end
end
