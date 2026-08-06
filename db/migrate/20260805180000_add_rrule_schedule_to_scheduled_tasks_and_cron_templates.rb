class AddRruleScheduleToScheduledTasksAndCronTemplates < ActiveRecord::Migration[8.1]
  class MigrationScheduledTask < ActiveRecord::Base
    self.table_name = "scheduled_tasks"
  end

  class MigrationCronTemplate < ActiveRecord::Base
    self.table_name = "cron_templates"
  end

  def up
    change_column_null :cron_templates, :cron_expression, true
    add_schedule_columns :scheduled_tasks
    add_schedule_columns :cron_templates

    MigrationScheduledTask.reset_column_information
    MigrationCronTemplate.reset_column_information

    migrate_existing_cron_rows(MigrationScheduledTask)
    migrate_existing_cron_rows(MigrationCronTemplate)
  end

  def down
    remove_schedule_columns :scheduled_tasks
    remove_schedule_columns :cron_templates
    change_column_null :cron_templates, :cron_expression, false
  end

  private

  def add_schedule_columns(table)
    add_column table, :schedule_input, :string unless column_exists?(table, :schedule_input)
    add_column table, :schedule_format, :string, default: "rrule", null: false unless column_exists?(table, :schedule_format)
    add_column table, :schedule_expression, :text unless column_exists?(table, :schedule_expression)
    add_column table, :schedule_timezone, :string, default: "UTC", null: false unless column_exists?(table, :schedule_timezone)
    add_column table, :legacy_cron_expression, :string unless column_exists?(table, :legacy_cron_expression)
  end

  def remove_schedule_columns(table)
    remove_column table, :schedule_input if column_exists?(table, :schedule_input)
    remove_column table, :schedule_format if column_exists?(table, :schedule_format)
    remove_column table, :schedule_expression if column_exists?(table, :schedule_expression)
    remove_column table, :schedule_timezone if column_exists?(table, :schedule_timezone)
    remove_column table, :legacy_cron_expression if column_exists?(table, :legacy_cron_expression)
  end

  def migrate_existing_cron_rows(model)
    model.where.not(cron_expression: nil).find_each do |record|
      rrule = rrule_for_cron(record.cron_expression)
      record.update_columns(
        schedule_input: record.cron_expression,
        schedule_format: "rrule",
        schedule_expression: rrule,
        schedule_timezone: "UTC",
        legacy_cron_expression: record.cron_expression
      )
    end
  end

  def rrule_for_cron(cron_expression)
    minute, hour, day_of_month, month, day_of_week = cron_expression.to_s.split(/\s+/)
    parts = [ "FREQ=#{frequency_for(hour, day_of_month, month, day_of_week)}" ]
    parts << "BYMONTH=#{month}" unless month == "*"
    parts << "BYMONTHDAY=#{day_of_month}" unless day_of_month == "*"
    parts << "BYDAY=#{rrule_days(day_of_week)}" unless day_of_week == "*"
    parts << "BYHOUR=#{hour}" unless hour == "*"
    parts << "BYMINUTE=#{minute}"
    parts << "BYSECOND=0"
    parts.join(";")
  end

  def frequency_for(hour, day_of_month, month, day_of_week)
    return "HOURLY" if hour == "*" && day_of_month == "*" && month == "*" && day_of_week == "*"
    return "YEARLY" unless month == "*"
    return "MONTHLY" unless day_of_month == "*"
    return "WEEKLY" unless day_of_week == "*"

    "DAILY"
  end

  def rrule_days(day_of_week)
    names = %w[SU MO TU WE TH FR SA]
    day_of_week.split(",").map { |day| names.fetch(Integer(day) % 7) }.join(",")
  end
end
