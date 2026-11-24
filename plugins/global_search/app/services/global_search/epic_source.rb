module GlobalSearch
  class EpicSource
    class << self
      def search_table_name = "epic_fts"
      def search_id_column = "epic_id"
      def records = Syrus::Host::Epic.order(:id)
      def count = Syrus::Host::Epic.count
      def exists? = Syrus::Host::Epic.exists?
      def upsert(epic) = EpicIndex.upsert(epic)
    end
  end
end
