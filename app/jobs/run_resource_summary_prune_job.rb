class RunResourceSummaryPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(scope: RunResourceSummary.prunable)
    Rails.logger.info("[RunResourceSummaryPruneJob] deleted #{deleted} run resource summaries") if deleted > 0
  end
end
