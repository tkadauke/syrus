class IndexEpicSearchJob < PluginJob
  plugin :global_search

  def perform(epic_id)
    epic = Epic.find_by(id: epic_id)
    return unless epic

    GlobalSearch::EpicIndex.upsert(epic)
  end
end
