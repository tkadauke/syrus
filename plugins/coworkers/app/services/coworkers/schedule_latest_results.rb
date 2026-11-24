module Coworkers
  class ScheduleLatestResults
    def initialize(tasks:, user:)
      @tasks = tasks
      @user = user
    end

    def call
      jobs = relevant_jobs
      tasks.index_with { |task| summary(task, jobs[task.id]) }
    end

    private

    attr_reader :tasks, :user

    def relevant_jobs
      targets = system_targets
      ordinary_task_ids = tasks.reject { |task| targets.key?(task.id) }.map(&:id)
      ids = visible_jobs.where(scheduled_task_id: ordinary_task_ids).group(:scheduled_task_id).maximum(:id).values
      candidates = jobs_for_targets(targets)
      jobs = Syrus::Host::Jobs.where(id: ids | candidates.map(&:id)).includes(workflows: :workflow_artifact_values).to_a

      jobs.select { |job| ordinary_task_ids.include?(job.scheduled_task_id) }
        .index_by(&:scheduled_task_id)
        .merge(matching_system_jobs(jobs, targets))
    end

    def visible_jobs
      Syrus::Host::Jobs.visible_to(user, scope: Syrus::Host::Jobs.where(scheduled_task_id: tasks.map(&:id)))
    end

    def system_targets
      tasks.filter_map do |task|
        history = Array(task.system_result_history).last
        [ task.id, history.fetch("date") ] if task.system_key.present? && history
      end.to_h
    end

    def jobs_for_targets(targets)
      return Syrus::Host::Jobs.none if targets.empty?

      visible_jobs.where(scheduled_task_id: targets.keys).joins(workflows: :workflow_artifact_values)
        .where(workflow_artifact_values: { key: "journaling_target_on", value: targets.values })
        .distinct
    end

    def matching_system_jobs(jobs, targets)
      matches = jobs.filter_map do |job|
        target = targets[job.scheduled_task_id]
        job if target && job.workflows.any? { |workflow| workflow.artifact("journaling_target_on") == target }
      end
      matches.group_by(&:scheduled_task_id).transform_values { |group| group.max_by(&:id) }
    end

    def summary(task, job)
      history = Array(task.system_result_history).last
      return system_summary(history, job) if task.system_key.present? && history
      return never_run unless job

      job_summary(job)
    end

    def system_summary(history, job)
      target_date = history.fetch("date")
      {
        occurred_at: history["recorded_at"], target_date: target_date,
        outcome: history.fetch("result"), reason: history["reason"],
        job: job && job_json(job), job_needed: job.present?
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
