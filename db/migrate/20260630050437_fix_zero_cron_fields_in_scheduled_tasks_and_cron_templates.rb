class FixZeroCronFieldsInScheduledTasksAndCronTemplates < ActiveRecord::Migration[8.1]
  def up
    fix_zero_cron_fields("ScheduledTask", ScheduledTask)
    fix_zero_cron_fields("CronTemplate", CronTemplate)
  end

  def down
    # No-op: restoring invalid cron expressions would be unsafe.
  end

  private

  def fix_zero_cron_fields(model_name, model)
    model.where.not(cron_expression: nil).find_each do |record|
      fields = record.cron_expression.to_s.split(/\s+/)
      next unless fields.length == 5

      original_expression = record.cron_expression
      fields[2] = "*" if fields[2] == "0"
      fields[3] = "*" if fields[3] == "0"
      new_expression = fields.join(" ")

      if new_expression != original_expression
        record.update_column(:cron_expression, new_expression)
      end

      warn_for_complex_zero_field(model_name, record, "day-of-month", fields[2]) if complex_zero_field?(fields[2])
      warn_for_complex_zero_field(model_name, record, "month", fields[3]) if complex_zero_field?(fields[3])
    end
  end

  def complex_zero_field?(field)
    return false if field == "0"

    field.to_s.split(",").any? do |element|
      value = element.strip.split("/", 2).first
      next false if value.blank? || value == "*"

      value.split("-", 2).any? { |part| part.match?(/\A0+\z/) }
    end
  end

  def warn_for_complex_zero_field(model_name, record, field_name, field)
    Rails.logger.warn(
      "[FixZeroCronFields] #{model_name} ##{record.id} cron_expression #{record.cron_expression.inspect} " \
      "has a complex zero #{field_name} field #{field.inspect}; review manually"
    )
  end
end
