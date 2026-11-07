module Coworkers
  # Coworkers owns Calendar presentation for its schedules. Scheduled Tasks
  # deliberately excludes these rows so each occurrence has exactly one owner.
  class CalendarEventSource < ScheduledTasks::CalendarEventSource
    def calendar_events
      @coworkers_by_id = Coworkers::Coworker
        .where(id: tasks.map(&:coworker_id))
        .includes(:avatar_attachment, coworker_chats: :chat_session)
        .index_by(&:id)
      super
    end

    private

    def tasks
      @tasks ||= ScheduledTasks::Task.where(user: user).where.not(coworker_id: nil)
        .where(repository_id: Repository.accessible_repository_ids_for(user))
        .includes(:repository)
        .joins("INNER JOIN coworkers ON coworkers.id = scheduled_tasks.coworker_id")
        .where(coworkers: { owner_user_id: user.id })
    end

    def visible_jobs_by_task(selected_tasks)
      task_ids = selected_tasks.map(&:id)
      return {} if task_ids.empty?

      scope = Job.where(scheduled_task_id: task_ids).includes(workflows: :work_unit).order(:created_at)
      Job.visible_to(user, scope:).to_a.group_by(&:scheduled_task_id)
    end

    def event(task, planned_at, job)
      coworker = @coworkers_by_id.fetch(task.coworker_id)
      main_chat = coworker.coworker_chats.find(&:main?)&.chat_session
      workflow = job&.workflows&.min_by(&:created_at)
      actual_started_at = workflow&.started_at || job&.started_at
      actual_finished_at = workflow&.finished_at || job&.finished_at

      {
        source_id: "coworkers:scheduled_work",
        id: "coworker-task-#{task.id}-#{planned_at.utc.strftime('%Y%m%dT%H%M%SZ')}",
        kind: "coworker_scheduled_task",
        title: task.name,
        starts_at: planned_at,
        actual_started_at:,
        actual_finished_at:,
        cadence: task.cron? ? { label: task.schedule_explanation || task.schedule_expression, band: false } : nil,
        destination_path: job ? "/jobs/#{job.id}" : "/coworkers/#{coworker.id}",
        state: coworker_occurrence_state(task, planned_at, job, workflow),
        metadata: {
          coworker_id: coworker.id,
          coworker_name: coworker.name,
          coworker_handle: coworker.handle,
          coworker_path: "/coworkers/#{coworker.id}",
          coworker_avatar_url: coworker.avatar_url,
          coworker_avatar_key: coworker.avatar_key,
          coworker_accent_hex: coworker.accent_hex,
          main_chat_id: main_chat&.id,
          main_chat_path: main_chat && "/chats/#{main_chat.id}",
          scheduled_task_id: task.id,
          scheduled_task_path: "/coworkers/#{coworker.id}?tab=schedules",
          repository_id: task.repository_id,
          repository: task.repository.slug,
          schedule_timezone: task.schedule_timezone,
          after_run: task.after_run,
          system_schedule: task.system_schedule?,
          system_key: task.system_key,
          job_id: job&.id,
          job_path: job && "/jobs/#{job.id}",
          workflow_id: workflow&.id,
          workflow_state: workflow&.state,
          duration_seconds: duration(actual_started_at, actual_finished_at),
          delayed_reason: workflow&.work_unit&.blocked_reason
        }.compact
      }
    end

    def coworker_occurrence_state(task, planned_at, job, workflow)
      return occurrence_state(task, planned_at, job, workflow) unless job
      return "failure" if workflow&.failed? || job.closure_reason.to_s.include?("fail")
      return "success" if workflow&.succeeded?
      return "running" if workflow&.started_at && !workflow.finished_at
      return "delayed" if workflow&.work_unit&.blocked_reason.present?

      "waiting"
    end

    def duration(started_at, finished_at)
      (finished_at - started_at).round(1) if started_at && finished_at
    end
  end
end
