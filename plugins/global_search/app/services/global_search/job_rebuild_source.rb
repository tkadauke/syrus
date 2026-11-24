module GlobalSearch
  class JobRebuildSource
    class << self
      def search_rebuild_key = "jobs"
      def search_rebuild_scope = Syrus::Host::JobRecord.order(:id)
      def index_search_record(job) = JobIndex.upsert(job)
    end
  end
end
