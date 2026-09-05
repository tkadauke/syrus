module ScheduledTasks
  # Propagates a fired Job's outcome back to the schedule that fired it, and
  # seeds the bootstrap admin's templates.
  #
  # These were Job#record_outcome_to_scheduled_task! on the close event, a
  # second `scheduled_task.record_failure!` on the runaway path, and
  # User#seed_default_cron_templates -- core models reaching into this
  # plugin's models. All three are events now.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    # Only the "too many" reasons consume the consecutive-failure cap that can
    # auto-pause a schedule. `replaced_by_scheduled_task` is bookkeeping for
    # the pile-replace policy -- neither a success nor a failure.
    OUTCOMES = {
      "too_many_failures"          => :record_failure!,
      "too_many_failed_workflows"  => :record_failure!,
      "too_many_workflows"         => :record_failure!,
      "replaced_by_scheduled_task" => nil
    }.freeze

    def self.subscriptions
      {
        "job.closed" => :on_job_closed,
        "job.runaway_stopped" => :on_job_runaway_stopped,
        "user.created" => :on_user_created
      }
    end

    def self.on_job_closed(event)
      task = task_for(event)
      return if task.nil?

      outcome = OUTCOMES.fetch(event[:closure_reason].to_s, :record_success!)
      task.public_send(outcome) if outcome
    rescue StandardError => e
      Rails.logger.error("[ScheduledTasks] outcome propagation failed for job #{event[:job_id]}: #{e.class}: #{e.message}")
    end

    # Runaway protection fails a Job without closing it, so this never arrives
    # as job.closed and the failure would otherwise go unrecorded.
    def self.on_job_runaway_stopped(event)
      task_for(event)&.record_failure!
    rescue StandardError => e
      Rails.logger.error("[ScheduledTasks] runaway failure propagation failed for job #{event[:job_id]}: #{e.class}: #{e.message}")
    end

    # Seeded for the installation's bootstrap admin only, so later signups do
    # not each accumulate their own copies.
    def self.on_user_created(event)
      return unless event[:first_user]

      user = User.find_by(id: event[:user_id])
      ScheduledTasks::CronTemplate.seed_defaults_for(user) if user
    rescue StandardError => e
      Rails.logger.error("[ScheduledTasks] template seeding failed for user #{event[:user_id]}: #{e.class}: #{e.message}")
    end

    # Found through the Job's origin rather than a foreign key on `jobs`.
    def self.task_for(event)
      return nil unless event[:origin].to_s == "scheduled_tasks"
      return nil if event[:origin_id].blank?

      ScheduledTasks::Task.find_by(id: event[:origin_id])
    end
    private_class_method :task_for
  end
end
