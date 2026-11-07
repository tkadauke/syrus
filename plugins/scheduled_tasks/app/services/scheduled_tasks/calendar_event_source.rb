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
      selected_tasks = tasks.to_a
      jobs_by_task = visible_jobs_by_task(selected_tasks)

      selected_tasks.flat_map do |task|
        planned_times = occurrences(task)
        jobs_by_occurrence = correlate_jobs(planned_times, jobs_by_task.fetch(task.id, []))
        planned_times.map { |planned_at| event(task, planned_at, jobs_by_occurrence[planned_at]) }
      end
    end

    private

    attr_reader :user, :starts_at, :ends_at

    def tasks
      ScheduledTasks::Task.where(user:, coworker_id: nil)
        .where(repository_id: Repository.accessible_repository_ids_for(user))
        .includes(:repository)
    end

    def visible_jobs_by_task(selected_tasks)
      task_ids = selected_tasks.map(&:id)
      return {} if task_ids.empty?

      scope = Job.where(scheduled_task_id: task_ids).includes(:workflows).order(:created_at)
      Job.visible_to(user, scope:).to_a.group_by(&:scheduled_task_id)
    end

    def occurrences(task)
      return one_shot_occurrences(task) if task.one_shot?

      schedule = ScheduledTasks::Schedules::RecurringSchedule.from_expression(
        task.schedule_expression, timezone: task.schedule_timezone
      )
      range_start = [ starts_at, task.created_at ].max
      range_end = [ ends_at, task.archived_at ].compact.min
      return [] if range_start >= range_end

      cursor = range_start - 1.second
      result = []
      MAX_OCCURRENCES_PER_TASK.times do
        occurrence = schedule.next_fire_at(from: cursor)
        break if occurrence.nil? || occurrence >= range_end
        cursor = occurrence
        result << occurrence
      end
      result
    rescue ArgumentError
      []
    end

    def one_shot_occurrences(task)
      return [] unless task.fire_at

      range_start = [ starts_at, task.created_at ].max
      range_end = [ ends_at, task.archived_at ].compact.min
      task.fire_at >= range_start && task.fire_at < range_end ? [ task.fire_at ] : []
    end

    def correlate_jobs(planned_times, jobs)
      unclaimed_jobs = jobs.dup
      planned_times.index_with do |planned_at|
        index = unclaimed_jobs.index do |job|
          job.created_at >= planned_at && job.created_at < planned_at + 1.hour
        end
        index && unclaimed_jobs.delete_at(index)
      end
    end

    def event(task, planned_at, job)
      workflow = job&.workflows&.min_by(&:created_at)
      {
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
      }
    end

    def occurrence_state(task, planned_at, job, workflow)
      return execution_state(job, workflow) if job
      return "fired" if task.fired?
      return "skipped" if planned_at < Time.current
      return task.state if task.paused? || task.auto_paused?

      "planned"
    end

    def execution_state(job, workflow)
      return "failure" if workflow&.state == "failed" || job.closure_reason.to_s.include?("fail")
      return "running" if workflow && !workflow.finished_at
      return "fired" if workflow || job

      "planned"
    end
  end
end
