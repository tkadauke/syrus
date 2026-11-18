class IndexEpicSearchJob < PluginJob
  plugin_name "global_search"
  queue_as :indexing

  def perform(epic_id)
    epic = Epic.find_by(id: epic_id)
    return unless epic

    GlobalSearch::EpicIndex.upsert(epic)
  end
end
