class IndexEpicSearchJob < PluginJob
  queue_as :indexing

  def perform(epic_id)
    epic = Epic.find_by(id: epic_id)
    return unless epic

    GlobalSearch::EpicIndex.upsert(epic)
  end
end
