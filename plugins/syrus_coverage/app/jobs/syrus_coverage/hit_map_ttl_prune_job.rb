class SyrusCoverage::HitMapTtlPruneJob < Syrus::Host::BackgroundJob
  include SkipIfPending

  queue_as :cleanup

  TTL_DAYS = 7

  def perform
    cutoff = TTL_DAYS.days.ago

    SyrusCoverage::HitMap.expired_workflow_ids(cutoff).each do |workflow_id|
      workflow = Workflow.find_by(id: workflow_id)
      SyrusCoverage::HitMap.purge_for!(workflow) if workflow
    rescue StandardError => e
      Rails.logger.warn("SyrusCoverage::HitMapTtlPruneJob: failed to purge workflow #{workflow_id}: #{e.message}")
    end
  end
end
