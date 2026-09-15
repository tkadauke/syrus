module GlobalSearch
  class EpicRebuildSource
    class << self
      def search_rebuild_key = "epics"
      def search_rebuild_scope = Epic.order(:id)
      def index_search_record(epic) = EpicIndex.upsert(epic)
    end
  end
end
