module GlobalSearch
  class EpicSource
    class << self
      def search_table_name = "epic_fts"
      def search_id_column = "epic_id"
      def records = Epic.order(:id)
      def count = Epic.count
      def exists? = Epic.exists?
      def upsert(epic) = EpicIndex.upsert(epic)
    end
  end
end
