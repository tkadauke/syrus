class WorkerHostHealthSamplePruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(scope: WorkerHostHealthSample.prunable)
    Rails.logger.info("[WorkerHostHealthSamplePruneJob] deleted #{deleted} worker host health samples") if deleted > 0
  end
end
