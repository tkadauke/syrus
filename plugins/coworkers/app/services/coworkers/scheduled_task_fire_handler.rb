module Coworkers
  class ScheduledTaskFireHandler < ScheduledTasks::FireHandlers::Base
    def applicable_behaviors = []

    def fire!(now:)
      coworker = Coworkers::Coworker.find(task.coworker_id)
      raise ArgumentError, "scheduled task owner does not own coworker" unless coworker.owner_user_id == task.user_id
      raise ArgumentError, "scheduled task repository is not the coworker's workspace" unless coworker.workspace_repository == task.repository

      target_date = journaling_target_date(now:, coworker:)
      system_schedule = task.respond_to?(:system_schedule?) && task.system_schedule?
      return ScheduledTasks::Fire::Result.new(job: nil, skipped: true, reason: "dormant") if system_schedule && target_date.nil?
      prompt = system_schedule ? task.prompt_for(target_date: target_date) : task.prompt
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
      WorkUnits::Launcher.start!(workflow, prompt: prompt)
      job
    end

    private

    def journaling_target_date(now:, coworker:)
      return unless task.respond_to?(:system_key) && task.system_key == Coworkers::SystemSchedules::JOURNALING

      date = Coworkers::SystemSchedules.target_date(task, now: now)
      while date && date <= now.in_time_zone(task.schedule_timezone).to_date - 1
        return date if Coworkers::JournalingActivity.new(coworker:, date:).active?

        task.update!(last_journaled_on: date, last_system_result: "skipped", last_system_result_on: date,
                     last_system_result_reason: "dormant")
        date += 1
      end
      nil
    end
  end
end
