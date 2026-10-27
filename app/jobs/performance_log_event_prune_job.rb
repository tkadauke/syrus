class PerformanceLogEventPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(scope: PerformanceLogEvent.prunable)
    Rails.logger.info("[PerformanceLogEventPruneJob] deleted #{deleted} performance log events") if deleted > 0
  end
end
