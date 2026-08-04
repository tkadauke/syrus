class UrgentJobClosedJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository

    return if repository.jobs.where(priority: "urgent").where.not(state: "closed").exists?

    Workflow
      .joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(state: "queued")
      .where.not(id: Workflow.joins(steps: :runs).select("workflows.id"))
      .find_each do |workflow|
        next unless workflow.artifact("start_blocked_reason") == StepDispatcher::URGENT_BLOCK_REASON
        StepDispatcher.start_workflow(workflow)
      end
  end
end
