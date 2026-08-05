class IndexOperationalLogEventJob < ApplicationJob
  queue_as :default

  def perform(operational_log_event_id)
    return unless OperationalLogging.configured_for_instance?

    OperationalLogging.suppress do
      event = OperationalLogEvent.find_by(id: operational_log_event_id)
      event ? OperationalLogIndex.upsert(event) : OperationalLogIndex.delete(operational_log_event_id)
    end
  end
end
