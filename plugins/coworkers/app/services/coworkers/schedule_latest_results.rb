module Coworkers
  class ScheduleLatestResults
    def initialize(tasks:, user:)
      @tasks = tasks
      @user = user
    end

    def call
      jobs = latest_jobs.index_by(&:scheduled_task_id)
      tasks.index_with { |task| summary(task, jobs[task.id]) }
    end

    private

    attr_reader :tasks, :user

    def latest_jobs
      scope = Job.visible_to(user, scope: Job.where(scheduled_task_id: tasks.map(&:id)))
      ids = scope.group(:scheduled_task_id).maximum(:id).values
      Job.where(id: ids).includes(workflows: :workflow_artifact_values).to_a
    end

    def summary(task, job)
      history = Array(task.system_result_history).last
      return system_summary(history, job) if task.system_key.present? && history
      return never_run unless job

      job_summary(job)
    end

    def system_summary(history, job)
      target_date = history.fetch("date")
      matching_job = job if job&.workflows&.any? { |workflow| workflow.artifact("journaling_target_on") == target_date }
      {
        occurred_at: history["recorded_at"], target_date: target_date,
        outcome: history.fetch("result"), reason: history["reason"],
        job: matching_job && job_json(matching_job), job_needed: matching_job.present?
      }
    end

    def job_summary(job)
      workflow = job.workflows.max_by { |item| [ item.created_at, item.id ] }
      {
        occurred_at: job.created_at.iso8601, target_date: nil,
        outcome: workflow&.state || job.state, reason: workflow&.failure_reason.presence,
        job: job_json(job), job_needed: true
      }
    end

    def never_run
      { occurred_at: nil, target_date: nil, outcome: "never_run", reason: nil, job: nil, job_needed: nil }
    end

    def job_json(job) = { id: job.id, slug: job.slug, path: "/jobs/#{job.id}" }
  end
end
