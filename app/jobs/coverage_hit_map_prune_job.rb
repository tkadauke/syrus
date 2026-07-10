class CoverageHitMapPruneJob < ApplicationJob
  queue_as :default

  def perform(workflow_id)
    wf = Workflow.find_by(id: workflow_id)
    return unless wf

    wf.purge_coverage_hit_map!
    Rails.logger.info("[CoverageHitMapPrune] purged hit map for Workflow ##{workflow_id}")
  end
end
