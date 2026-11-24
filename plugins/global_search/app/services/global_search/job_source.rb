module GlobalSearch
  class JobSource
    class << self
      def search_table_name = "job_fts"
      def search_id_column = "job_id"
      def records = Syrus::Host::JobRecord.order(:id)
      def count = Syrus::Host::JobRecord.count
      def exists? = Syrus::Host::JobRecord.exists?
      def upsert(job) = JobIndex.upsert(job)
    end
  end
end
