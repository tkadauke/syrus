class WorkerHostHealthSamplePruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = WorkerHostHealthSample.prunable.delete_all
    Rails.logger.info("[WorkerHostHealthSamplePruneJob] deleted #{deleted} worker host health samples") if deleted > 0
  end
end
