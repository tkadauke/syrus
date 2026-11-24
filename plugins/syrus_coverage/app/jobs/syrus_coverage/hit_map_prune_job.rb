class SyrusCoverage::HitMapPruneJob < Syrus::Host::BackgroundJob
  queue_as :cleanup

  def perform(workflow_id)
    wf = Workflow.find_by(id: workflow_id)
    return unless wf

    SyrusCoverage::HitMap.purge_for!(wf)
    Rails.logger.info("[SyrusCoverage::HitMapPrune] purged hit map for Workflow ##{workflow_id}")
  end
end
