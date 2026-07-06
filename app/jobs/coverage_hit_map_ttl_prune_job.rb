class CoverageHitMapTtlPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  TTL_DAYS = 7

  def perform
    cutoff = TTL_DAYS.days.ago

    Workflow.where("created_at < ?", cutoff)
            .find_each do |workflow|
      next unless workflow.coverage_hit_map.attached?

      workflow.purge_coverage_hit_map!
    rescue StandardError => e
      Rails.logger.warn("CoverageHitMapTtlPruneJob: failed to purge workflow #{workflow.id}: #{e.message}")
    end
  end
end
