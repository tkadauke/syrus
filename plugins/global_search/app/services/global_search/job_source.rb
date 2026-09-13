module GlobalSearch
  class JobSource
    class << self
      def search_table_name = "job_fts"
      def search_id_column = "job_id"
      def records = Job.order(:id)
      def count = Job.count
      def exists? = Job.exists?
      def upsert(job) = JobIndex.upsert(job)
    end
  end
end
