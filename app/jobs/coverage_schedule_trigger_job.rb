# Enqueued by Steps::CoverageAnalyze when on_miss: schedule and coverage falls
# below the configured threshold. Creates a direct Job with the operator's
# schedule_prompt so the agent can improve coverage in a separate run.
class CoverageScheduleTriggerJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(workflow_id)
    workflow = Workflow.find_by(id: workflow_id)
    return unless workflow

    repo = workflow.job.repository
    user = workflow.job.user

    workspace_path = WorkflowWorkspace.path_for(workflow)
    plan = RepoCoveragePlan.for(workspace_path)

    return unless plan&.on_miss == "schedule" && plan.schedule_prompt.present?

    existing = user.jobs
                   .where(repository: repo, kind: "direct")
                   .where.not(state: "closed")
                   .where(created_at: 24.hours.ago..)
                   .joins(job_tags: :tag)
                   .where(tags: { name: "coverage-improvement" })
                   .exists?
    return if existing

    job = user.jobs.create!(
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Improve test coverage",
      title_pending: false,
      issue_body: plan.schedule_prompt,
      agent_provider: repo.effective_agent_provider
    )

    tag = user.tags.find_or_create_by!(name: "coverage-improvement") { |t| t.color = "gray" }
    job.job_tags.find_or_create_by!(tag: tag)

    job.advance_after_triage! if job.may_advance_after_triage?

    Rails.logger.info("[CoverageScheduleTrigger] created Job ##{job.id} for Workflow ##{workflow_id}")
  end
end
