module Coworkers
  class SystemSchedules
    JOURNALING = "journaling".freeze
    CATCH_UP_LIMIT = 7
    HEALTH_WINDOW = 25.hours

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

      def target_dates(task, now: Time.current)
        zone = ActiveSupport::TimeZone[task.schedule_timezone] || ActiveSupport::TimeZone["UTC"]
        yesterday = now.in_time_zone(zone).to_date - 1
        failed_dates = Array(task.system_result_history).filter_map do |entry|
          Date.iso8601(entry["date"]) if entry["result"] == "failed" && entry["date"].present?
        rescue Date::Error
          nil
        end
        # A future timestamp can appear under clock skew (and in time-travel
        # tests); never let it suppress the most recently completed local day.
        created_on = [ task.created_at.in_time_zone(zone).to_date, yesterday ].min
        next_unprocessed = task.last_journaled_on ? task.last_journaled_on + 1 : created_on
        first = ([ next_unprocessed ] + failed_dates.select { |date| date <= yesterday }).min
        return [] if first > yesterday

        first.upto([ first + CATCH_UP_LIMIT - 1, yesterday ].min).to_a
      end

      # Active coworkers old enough to have completed a full health window
      # must have a durable fire (including dormant skips) inside that window.
      # This backs the periodically sampled fleet-health metric.
      def unhealthy_count(now: Time.current)
        cutoff = now - HEALTH_WINDOW
        eligible_ids = Coworkers::Coworker.where(state: "active").where(created_at: ..cutoff).select(:id)
        healthy_ids = ScheduledTasks::Task.alive
          .where(state: "scheduled", system_key: JOURNALING, coworker_id: eligible_ids)
          .where(last_fired_at: cutoff..)
          .select(:coworker_id)

        Coworkers::Coworker.where(id: eligible_ids).where.not(id: healthy_ids).count
      end

      private

      def attributes_for(coworker)
        zone = coworker.owner_user.time_zone
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
