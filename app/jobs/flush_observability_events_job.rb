class FlushObservabilityEventsJob < ApplicationJob
  queue_as :low_priority_maintenance

  DELETE_BATCH_SIZE = Integer(ENV["SYRUS_OBSERVABILITY_PRUNE_BATCH_SIZE"], exception: false) || 100
  MAX_DELETE_BATCHES = Integer(ENV["SYRUS_OBSERVABILITY_PRUNE_MAX_BATCHES"], exception: false) || 50

  def perform
    PerformanceLogging.suppress do
      Observability::EventSink.flush!
      prune_expired(PerformanceLogEvent)
      prune_expired(WorkflowActivityEvent)
    end
  end

  private

  def prune_expired(model)
    deleted = 0
    MAX_DELETE_BATCHES.times do
      ids = model.expired.reorder(nil).limit(DELETE_BATCH_SIZE).pluck(:id)
      break if ids.empty?

      batch_deleted = model.where(id: ids).delete_all
      break if batch_deleted.zero?

      deleted += batch_deleted
    end
    Rails.logger.info("[FlushObservabilityEventsJob] pruned #{deleted} #{model.name} rows") if deleted.positive?
    deleted
  end
end
