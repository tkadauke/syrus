class IndexEpicSearchJob < ApplicationJob
  queue_as :default

  def perform(epic_id)
    epic = Epic.find_by(id: epic_id)
    return unless epic

    EpicSearchIndex.upsert(epic)
  end
end
