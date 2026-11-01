module GlobalSearch
  class JobSearchSource
    TABLE_NAME = "job_fts"
    ID_COLUMN = "job_id"

    def self.search_backfill_table_name = TABLE_NAME
    def self.search_backfill_step_key = "jobs"
    def self.search_backfill_step_title = "Index jobs"
    def self.search_backfill_record_label = "job"
    def self.search_backfill_total_count = Job.count

    def self.search_backfill_needed?
      indexed_count < Job.count
    end

    def self.search_database_rebuild_key = "jobs"
    def self.search_database_content_version = "1"
    def self.current_content_version = SearchIndexVersion.current(search_database_rebuild_key)
    def self.finish_content_version! = SearchIndexVersion.write!(search_database_rebuild_key, search_database_content_version)
    def self.search_database_tables = [ TABLE_NAME ]
    def self.search_database_rebuild_units = Job.count
    def self.search_database_initialize_content_version! = finish_content_version! unless current_content_version
    def self.search_database_integrity_repair_needed? = search_database_rebuild_pending?

    def self.search_database_rebuild_pending?
      search_backfill_needed?
    rescue StandardError
      Job.exists?
    end

    def self.search_backfill_batch(after_id:, limit:)
      last_id = after_id.to_i
      processed = 0

      Job.order(:id).where("id > ?", last_id).limit(SearchIndexWriteLimits.clamp_rows(limit)).find_each do |job|
        JobIndex.upsert(job)
        last_id = job.id
        processed += 1
      end

      { processed: processed, last_id: last_id, done: processed.zero? || last_id >= Job.maximum(:id).to_i }
    end

    def self.search_database_rebuild_batch(task:, reason:)
      task.current_step_key = "jobs"
      task.current_step_title = "Index jobs"
      if reason == "version_mismatch" && !task.checkpoint["jobs_prepared"]
        SearchRecord.connection.execute("DELETE FROM #{TABLE_NAME}")
        task.checkpoint_will_change!
        task.checkpoint["jobs_prepared"] = true
        task.checkpoint["last_job_id"] = 0
      end
      batch = search_backfill_batch(after_id: task.checkpoint["last_job_id"].to_i, limit: task.batch_size)
      task.checkpoint_will_change!
      task.checkpoint["last_job_id"] = batch[:last_id] if batch[:last_id].present?
      task.checkpoint["jobs_done"] = true if batch[:done]
      finish_content_version! if batch[:done]
      processed = batch[:processed].to_i

      MaintenanceTasks::Definitions::Base::Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} job(s).", level: "progress")
    end

    def self.indexed_count(table = TABLE_NAME, id_column = ID_COLUMN)
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{id_column}) FROM #{table}").to_i
    end
    private_class_method :indexed_count
  end
end
