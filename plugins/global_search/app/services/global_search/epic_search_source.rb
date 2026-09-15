module GlobalSearch
  class EpicSearchSource
    def self.search_database_rebuild_key = "epics"
    def self.search_database_rebuild_units = Epic.count

    def self.search_database_rebuild_pending?
      indexed_count("epic_fts", "epic_id") < Epic.count
    rescue StandardError
      Epic.exists?
    end

    def self.search_database_rebuild_batch(task:)
      task.current_step_key = "epics"
      task.current_step_title = "Index epics"
      processed = 0
      Epic.order(:id).where("id > ?", task.checkpoint["last_epic_id"].to_i).limit(task.batch_size).find_each do |epic|
        EpicIndex.upsert(epic)
        task.checkpoint_will_change!
        task.checkpoint["last_epic_id"] = epic.id
        processed += 1
      end
      task.checkpoint_will_change!
      task.checkpoint["epics_done"] = true if processed.zero? || task.checkpoint["last_epic_id"].to_i >= Epic.maximum(:id).to_i

      MaintenanceTasks::Definitions::Base::Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} epic(s).", level: "progress")
    end

    def self.indexed_count(table, id_column)
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{id_column}) FROM #{table}").to_i
    end
    private_class_method :indexed_count
  end
end
