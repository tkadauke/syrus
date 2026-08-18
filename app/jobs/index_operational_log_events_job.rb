class IndexOperationalLogEventsJob < ApplicationJob
  queue_as :indexing

  def perform(operational_log_event_ids)
    return unless OperationalLogging.configured_for_instance?

    ids = Array(operational_log_event_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    return if ids.empty?

    OperationalLogging.suppress do
      events_by_id = OperationalLogEvent.where(id: ids).index_by(&:id)
      OperationalLogIndex.connection.transaction do
        ids.each do |id|
          event = events_by_id[id]
          event ? OperationalLogIndex.upsert(event) : OperationalLogIndex.delete(id)
        end
      end
    end
  end
end
