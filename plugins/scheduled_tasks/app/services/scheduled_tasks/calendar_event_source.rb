module ScheduledTasks
  # Read-only Calendar contribution. Calendar owns aggregation and rendering;
  # this provider keeps schedule authorization and execution correlation here.
  class CalendarEventSource
    MAX_OCCURRENCES_PER_TASK = 1_008

    def self.calendar_events(user:, starts_at:, ends_at:)
      new(user:, starts_at:, ends_at:).calendar_events
    end

    def initialize(user:, starts_at:, ends_at:)
      @user = user
      @starts_at = starts_at
      @ends_at = ends_at
    end

    def calendar_events
      tasks.flat_map do |task|
        jobs = visible_jobs(task)
        occurrences(task).map { |planned_at| event(task, planned_at, matching_job(jobs, planned_at)) }
      end
    end

    private

    attr_reader :user, :starts_at, :ends_at

    def tasks
      repository_ids = user.admin? ? Repository.all.select(:id) : Repository.accessible_repository_ids_for(user)
      ScheduledTasks::Task.where(coworker_id: nil)
        .where(repository_id: repository_ids)
        .includes(:repository, jobs: :workflows)
    end

    def visible_jobs(task)
      Job.visible_to(user, scope: task.jobs).order(:created_at).to_a
    end

    def occurrences(task)
      return one_shot_occurrences(task) if task.one_shot?

      schedule = ScheduledTasks::Schedules::RecurringSchedule.from_expression(
        task.schedule_expression, timezone: task.schedule_timezone
      )
      cursor = starts_at - 1.second
      result = []
      MAX_OCCURRENCES_PER_TASK.times do
        occurrence = schedule.next_fire_at(from: cursor)
        break if occurrence.nil? || occurrence >= ends_at
        cursor = occurrence
        result << occurrence
      end
      result
    rescue ArgumentError
      []
    end

    def one_shot_occurrences(task)
      task.fire_at && task.fire_at >= starts_at && task.fire_at < ends_at ? [ task.fire_at ] : []
    end

    def matching_job(jobs, planned_at)
      jobs.select { |job| job.created_at >= planned_at && job.created_at < planned_at + 1.hour }
        .min_by(&:created_at)
    end

    def event(task, planned_at, job)
      workflow = job&.workflows&.min_by(&:created_at)
      Calendar::Event.new(
        source_id: "scheduled_tasks:tasks",
        id: "task-#{task.id}-#{planned_at.utc.strftime('%Y%m%dT%H%M%SZ')}",
        kind: "scheduled_task",
        title: task.name,
        starts_at: planned_at,
        actual_started_at: workflow&.started_at || job&.started_at || job&.created_at,
        actual_finished_at: workflow&.finished_at || job&.finished_at,
        cadence: task.cron? ? { label: task.schedule_explanation || task.schedule_expression, band: false } : nil,
        destination_path: job ? "/jobs/#{job.id}" : "/scheduled_tasks/#{task.id}",
        state: occurrence_state(task, planned_at, job, workflow),
        metadata: {
          scheduled_task_id: task.id,
          scheduled_task_path: "/scheduled_tasks/#{task.id}",
          repository_id: task.repository_id,
          repository: task.repository.slug,
          schedule_timezone: task.schedule_timezone,
          pr_pileup_policy: task.pr_pileup_policy,
          job_id: job&.id,
          job_path: job && "/jobs/#{job.id}",
          workflow_id: workflow&.id,
          workflow_state: workflow&.state
        }.compact
      )
    end

    def occurrence_state(task, planned_at, job, workflow)
      return execution_state(job, workflow) if job
      return "archived" if task.archived?
      return task.state if task.paused? || task.auto_paused?
      return "skipped" if planned_at < Time.current && fired_without_job?(task, planned_at)
      return "fired" if task.fired?

      "planned"
    end

    def execution_state(job, workflow)
      return "failure" if workflow&.state == "failed" || job.closure_reason.to_s.include?("fail")
      return "running" if workflow && !workflow.finished_at
      return "fired" if workflow || job

      "planned"
    end

    def fired_without_job?(task, planned_at)
      task.last_fired_at && task.last_fired_at >= planned_at && task.last_fired_at < planned_at + 1.hour
    end
  end
end
