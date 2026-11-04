module Coworkers
  class SystemSchedules
    JOURNALING = "journaling".freeze
    CATCH_UP_LIMIT = 7

    class << self
      def reconcile!(coworker)
        return unless coworker.state == "active"
        return unless coworker.workspace_repository

        task = coworker.schedules.find_or_initialize_by(system_key: JOURNALING)
        task.assign_attributes(attributes_for(coworker)) if task.new_record?
        repair!(task, coworker) unless task.new_record?
        task.save!
        desired_zone = attributes_for(coworker).fetch(:schedule_timezone)
        task.update_column(:schedule_timezone, desired_zone) if task.schedule_timezone != desired_zone
        task
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def target_date(task, now: Time.current)
        zone = ActiveSupport::TimeZone[task.schedule_timezone] || ActiveSupport::TimeZone["UTC"]
        yesterday = now.in_time_zone(zone).to_date - 1
        first = task.last_journaled_on ? task.last_journaled_on + 1 : yesterday
        [ first, yesterday - (CATCH_UP_LIMIT - 1) ].max.upto(yesterday).first
      end

      private

      def attributes_for(coworker)
        zone = coworker.owner_user.approval_delivery_preferences["time_zone"].presence || "UTC"
        {
          user: coworker.owner_user, repository: coworker.workspace_repository, coworker_id: coworker.id,
          name: "Journaling", kind: "cron", prompt: nil, schedule_input: "30 0 * * *", schedule_timezone: zone,
          after_run: "quiet", pr_pileup_policy: "skip", auto_approve_mode: "never", state: "scheduled"
        }
      end

      def repair!(task, coworker)
        desired = {
          user_id: coworker.owner_user_id, repository_id: coworker.workspace_repository.id,
          coworker_id: coworker.id, name: "Journaling", kind: "cron", after_run: "quiet", prompt: nil
        }
        task.update_columns(desired) if
          task.name != "Journaling" || task.kind != "cron" || task.after_run != "quiet" || task.prompt.present?
      end
    end
  end
end
