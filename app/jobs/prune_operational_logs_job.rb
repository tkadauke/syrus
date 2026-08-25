class PruneOperationalLogsJob < ApplicationJob
  queue_as :cleanup

  DELETE_BATCH_SIZE = Integer(ENV["SYRUS_OPERATIONAL_LOG_PRUNE_BATCH_SIZE"], exception: false) || 500
  MAX_DELETE_BATCHES = Integer(ENV["SYRUS_OPERATIONAL_LOG_PRUNE_MAX_BATCHES"], exception: false) || 50

  def perform(cutoff = OperationalLogEvent::RETENTION.ago)
    return unless OperationalLogging.configured_for_instance?

    cutoff = Time.zone.parse(cutoff.to_s) if cutoff.is_a?(String)
    cutoff ||= OperationalLogEvent::RETENTION.ago
    OperationalLogging.suppress do
      OperationalLogIndex.prune_before(cutoff)

      MAX_DELETE_BATCHES.times do
        ids = OperationalLogEvent.where(occurred_at: ...cutoff).reorder(nil).limit(DELETE_BATCH_SIZE).pluck(:id)
        break if ids.empty?

        OperationalLogEvent.where(id: ids).delete_all
      end
    end
  end
end
