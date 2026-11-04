module Coworkers
  class ScheduledTaskFireHandler < ScheduledTasks::FireHandlers::Base
    def applicable_behaviors = []

    def fire!(now:)
      coworker = Coworkers::Coworker.find(task.coworker_id)
      raise ArgumentError, "scheduled task owner does not own coworker" unless coworker.owner_user_id == task.user_id
      raise ArgumentError, "scheduled task repository is not the coworker's workspace" unless coworker.workspace_repository == task.repository

      system_schedule = task.respond_to?(:system_schedule?) && task.system_schedule?
      if system_schedule
        job = fire_journaling_catch_up!(now:, remaining: Coworkers::SystemSchedules::CATCH_UP_LIMIT)
        return ScheduledTasks::Fire::Result.new(job: nil, skipped: true, reason: "dormant") unless job
        return job
      end

      create_job(coworker:, prompt: task.prompt)
    end

    def fire_journaling_catch_up!(now: Time.current, remaining:, after_date: nil)
      coworker = Coworkers::Coworker.find(task.coworker_id)
      dates = Coworkers::SystemSchedules.target_dates(task, now: now)
      dates = dates.select { |date| date > after_date } if after_date
      dates.first(remaining).each_with_index do |date, index|
        activity = Coworkers::JournalingActivity.new(coworker:, date:)
        unless activity.active?
          task.record_system_result!(date:, result: "skipped", reason: "dormant")
          next
        end
        left = remaining - index - 1
        return create_job(coworker:, prompt: task.prompt_for(target_date: date), target_date: date,
                          catch_up_remaining: left)
      end
      nil
    end

    private

    def create_job(coworker:, prompt:, target_date: nil, catch_up_remaining: nil)
      job = Job.create!(
        user: task.user,
        repository: task.repository,
        kind: "coworker_task",
        priority: "low",
        scheduled_task_id: task.id,
        origin: "coworkers",
        origin_id: coworker.id.to_s,
        issue_title: "Scheduled coworker task: #{task.name}#{" for #{target_date}" if target_date}",
        issue_body: prompt,
        issue_number: nil
      )
      job.advance_after_triage! if job.may_advance_after_triage?
      workflow = WorkUnits::Launcher.instantiate(kind: "coworker_run", job: job)
      if target_date
        workflow.set_artifact!("journaling_target_on", target_date.iso8601)
        workflow.set_artifact!("journaling_catch_up_remaining", catch_up_remaining)
      end
      WorkUnits::Launcher.start!(workflow, prompt: prompt)
      job
    end
  end
end
