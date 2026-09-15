module GlobalSearch
  class JobSearchSource
    def self.search_database_rebuild_key = "jobs"
    def self.search_database_rebuild_units = Job.count

    def self.search_database_rebuild_pending?
      indexed_count("job_fts", "job_id") < Job.count
    rescue StandardError
      Job.exists?
    end

    def self.search_database_rebuild_batch(task:)
      task.current_step_key = "jobs"
      task.current_step_title = "Index jobs"
      processed = 0
      Job.order(:id).where("id > ?", task.checkpoint["last_job_id"].to_i).limit(task.batch_size).find_each do |job|
        JobIndex.upsert(job)
        task.checkpoint_will_change!
        task.checkpoint["last_job_id"] = job.id
        processed += 1
      end
      task.checkpoint_will_change!
      task.checkpoint["jobs_done"] = true if processed.zero? || task.checkpoint["last_job_id"].to_i >= Job.maximum(:id).to_i

      MaintenanceTasks::Definitions::Base::Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} job(s).", level: "progress")
    end

    def self.indexed_count(table, id_column)
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{id_column}) FROM #{table}").to_i
    end
    private_class_method :indexed_count
  end
end
