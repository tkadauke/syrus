class IndexBrowserErrorEventsJob < ApplicationJob
  queue_as :indexing

  def perform(browser_error_event_ids)
    ids = Array(browser_error_event_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    return if ids.empty?

    events_by_id = BrowserErrorEvent.where(id: ids).index_by(&:id)
    ids.each do |id|
      event = events_by_id[id]
      event ? BrowserErrorIndex.upsert(event) : BrowserErrorIndex.delete(id)
    end
  end
end
