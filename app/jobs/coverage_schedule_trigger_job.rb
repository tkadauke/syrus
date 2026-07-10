# Skeleton — full implementation tracked in a separate Job (EPIC-154 follow-up).
# Enqueued by Steps::CoverageAnalyze when on_miss: schedule and coverage falls
# below the configured threshold. Responsible for creating a direct Job with a
# coverage-improvement prompt so the agent can fix the gap.
class CoverageScheduleTriggerJob < ApplicationJob
  queue_as :default

  def perform(workflow_id)
    workflow = Workflow.find_by(id: workflow_id)
    return unless workflow

    Rails.logger.info("[CoverageScheduleTrigger] coverage threshold missed for Workflow ##{workflow_id} — trigger not yet implemented")
  end
end
