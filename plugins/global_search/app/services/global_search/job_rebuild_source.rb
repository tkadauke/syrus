module GlobalSearch
  class JobRebuildSource
    class << self
      def search_rebuild_key = "jobs"
      def search_rebuild_scope = Job.order(:id)
      def index_search_record(job) = JobIndex.upsert(job)
    end
  end
end
