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
    rescue StandardError
      Job.exists?
    end

    def self.search_backfill_batch(after_id:, limit:)
      last_id = after_id.to_i
      processed = 0

      Job.order(:id).where("id > ?", last_id).limit(limit).find_each do |job|
        JobIndex.upsert(job)
        last_id = job.id
        processed += 1
      end

      { processed: processed, last_id: last_id, done: processed.zero? || last_id >= Job.maximum(:id).to_i }
    end

    def self.indexed_count
      return 0 unless SyrusSearchDatabaseTasks.table_exists?(TABLE_NAME)

      SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{ID_COLUMN}) FROM #{TABLE_NAME}").to_i
    end
  end
end
