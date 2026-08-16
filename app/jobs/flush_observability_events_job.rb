class FlushObservabilityEventsJob < ApplicationJob
  queue_as :low_priority_maintenance

  DELETE_BATCH_SIZE = Integer(ENV["SYRUS_OBSERVABILITY_PRUNE_BATCH_SIZE"], exception: false) || 1_000
  MAX_DELETE_BATCHES = Integer(ENV["SYRUS_OBSERVABILITY_PRUNE_MAX_BATCHES"], exception: false) || 50

  def perform
    Observability::EventSink.flush!
    prune_expired(PerformanceLogEvent)
    prune_expired(WorkflowActivityEvent)
  end

  private

  def prune_expired(model)
    deleted = 0
    MAX_DELETE_BATCHES.times do
      batch_deleted = model.expired.order(:id).limit(DELETE_BATCH_SIZE).delete_all
      break if batch_deleted.zero?

      deleted += batch_deleted
    end
    Rails.logger.info("[FlushObservabilityEventsJob] pruned #{deleted} #{model.name} rows") if deleted.positive?
    deleted
  end
end
