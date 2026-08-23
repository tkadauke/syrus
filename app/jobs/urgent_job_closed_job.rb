class UrgentJobClosedJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository

    return if repository.jobs.where(priority: "urgent").where.not(state: "closed").exists?

    workflows_to_resume(repository).each do |workflow|
      WorkUnits::Launcher.start!(workflow)
    end
  end

  private

  def workflows_to_resume(repository)
    (work_unit_blocked_workflows(repository) + legacy_blocked_workflows(repository)).uniq(&:id)
  end

  def work_unit_blocked_workflows(repository)
    WorkUnit
      .joins(workflow: :job)
      .where(state: "blocked", blocked_reason: "urgent_job_active")
      .where(workflows: { state: "queued" })
      .where(jobs: { repository_id: repository.id })
      .where.not(workflows: { id: Workflow.joins(steps: :runs).select("workflows.id") })
      .includes(:workflow)
      .order(:id)
      .map(&:workflow)
  end

  def legacy_blocked_workflows(repository)
    Workflow
      .joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(state: "queued")
      .where.not(id: Workflow.joins(steps: :runs).select("workflows.id"))
      .select { |workflow| WorkUnits::StartBlock.for(workflow).blocked_for?(StepDispatcher::URGENT_BLOCK_REASON) }
  end
end
