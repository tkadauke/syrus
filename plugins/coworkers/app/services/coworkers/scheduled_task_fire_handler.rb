module Coworkers
  class ScheduledTaskFireHandler < ScheduledTasks::FireHandlers::Base
    def applicable_behaviors = []

    def fire!(now:)
      coworker = Coworkers::Coworker.find(task.coworker_id)
      raise ArgumentError, "scheduled task owner does not own coworker" unless coworker.owner_user_id == task.user_id
      raise ArgumentError, "scheduled task repository is not the coworker's workspace" unless coworker.workspace_repository == task.repository

      job = Job.create!(
        user: task.user,
        repository: task.repository,
        kind: "coworker_task",
        priority: "low",
        scheduled_task_id: task.id,
        origin: "coworkers",
        origin_id: coworker.id.to_s,
        issue_title: "Scheduled coworker task: #{task.name}",
        issue_body: task.prompt,
        issue_number: nil,
        planned_execution_capabilities: { "os" => [ "linux" ], "runtime" => [ Coworkers::PrivilegedGrantGate::CONFINEMENT_RUNTIME ] },
        planned_execution_source: "explicit"
      )
      job.advance_after_triage! if job.may_advance_after_triage?
      workflow = WorkUnits::Launcher.instantiate(kind: "coworker_run", job: job)
      WorkUnits::Launcher.start!(workflow, prompt: task.prompt)
      job
    end
  end
end
