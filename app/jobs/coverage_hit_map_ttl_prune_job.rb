class CoverageHitMapTtlPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  TTL_DAYS = 7

  def perform
    cutoff = TTL_DAYS.days.ago

    Workflow.joins(:coverage_hit_map_attachment)
            .where("workflows.created_at < ?", cutoff)
            .find_each do |workflow|
      workflow.purge_coverage_hit_map!
    rescue StandardError => e
      Rails.logger.warn("CoverageHitMapTtlPruneJob: failed to purge workflow #{workflow.id}: #{e.message}")
    end
  end
end
