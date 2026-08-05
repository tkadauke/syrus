class PruneOperationalLogsJob < ApplicationJob
  queue_as :cleanup

  def perform(cutoff = OperationalLogEvent::RETENTION.ago)
    return unless OperationalLogging.configured_for_instance?

    cutoff = Time.zone.parse(cutoff.to_s) if cutoff.is_a?(String)
    cutoff ||= OperationalLogEvent::RETENTION.ago
    OperationalLogging.suppress do
      OperationalLogEvent.where(occurred_at: ...cutoff).delete_all
      OperationalLogIndex.prune_before(cutoff)
    end
  end
end
