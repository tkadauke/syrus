class IndexEpicSearchJob < Syrus::Host::PluginJob
  plugin :global_search

  def perform(epic_id)
    epic = Syrus::Host::Epic.find_by(id: epic_id)
    return unless epic

    GlobalSearch::EpicIndex.upsert(epic)
  end
end
