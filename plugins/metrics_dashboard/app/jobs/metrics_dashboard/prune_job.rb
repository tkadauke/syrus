module MetricsDashboard
  # Enforces the retention window. Fixed resolution and fixed retention are what
  # keep this a rollup table rather than an unbounded time-series database
  # growing inside the primary database.
  class PruneJob < ApplicationJob
    queue_as :cleanup

    def perform
      deleted = MetricsDashboard::Sample.prunable.delete_all
      Rails.logger.info("[MetricsDashboard::PruneJob] pruned #{deleted} samples") if deleted.positive?
      deleted
    end
  end
end
