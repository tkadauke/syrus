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
    end

    def self.search_database_rebuild_key = "epics"
    def self.search_database_rebuild_units = Epic.count

    def self.search_database_rebuild_pending?
      search_backfill_needed?
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

    def self.search_database_rebuild_batch(task:)
      task.current_step_key = "epics"
      task.current_step_title = "Index epics"
      batch = search_backfill_batch(after_id: task.checkpoint["last_epic_id"].to_i, limit: task.batch_size)
      task.checkpoint_will_change!
      task.checkpoint["last_epic_id"] = batch[:last_id] if batch[:last_id].present?
      task.checkpoint["epics_done"] = true if batch[:done]
      processed = batch[:processed].to_i

      MaintenanceTasks::Definitions::Base::Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} epic(s).", level: "progress")
    end

    def self.indexed_count(table = TABLE_NAME, id_column = ID_COLUMN)
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{id_column}) FROM #{table}").to_i
    end
    private_class_method :indexed_count
  end
end
