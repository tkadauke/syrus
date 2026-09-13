module GlobalSearch
  class EpicSearchSource
    TABLE_NAME = "epic_fts"
    ID_COLUMN = "epic_id"

    def self.search_backfill_table_name = TABLE_NAME
    def self.search_backfill_step_key = "epics"
    def self.search_backfill_step_title = "Index epics"
    def self.search_backfill_record_label = "epic"
    def self.search_backfill_total_count = Epic.count

    def self.search_backfill_needed?
      indexed_count < Epic.count
    rescue StandardError
      Epic.exists?
    end

    def self.search_backfill_batch(after_id:, limit:)
      last_id = after_id.to_i
      processed = 0

      Epic.order(:id).where("id > ?", last_id).limit(limit).find_each do |epic|
        EpicIndex.upsert(epic)
        last_id = epic.id
        processed += 1
      end

      { processed: processed, last_id: last_id, done: processed.zero? || last_id >= Epic.maximum(:id).to_i }
    end

    def self.indexed_count
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(TABLE_NAME)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{ID_COLUMN}) FROM #{TABLE_NAME}").to_i
    end
  end
end
