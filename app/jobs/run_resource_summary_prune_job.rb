class RunResourceSummaryPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    deleted = RunResourceSummary.prunable.delete_all
    Rails.logger.info("[RunResourceSummaryPruneJob] deleted #{deleted} run resource summaries") if deleted > 0
  end
end
