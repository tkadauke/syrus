class IndexOperationalLogEventsJob < ApplicationJob
  queue_as :indexing

  def perform(operational_log_event_ids)
    return unless OperationalLogging.configured_for_instance?

    ids = Array(operational_log_event_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    return if ids.empty?

    OperationalLogging.suppress do
      ids.each_slice(SearchIndexWriteLimits::MAX_BATCH_ROWS) do |slice|
        OperationalLogIndex.upsert_many(
          OperationalLogEvent.where(id: slice).find_each(batch_size: 1),
          delete_ids: slice
        )
      end
    end
  end
end
