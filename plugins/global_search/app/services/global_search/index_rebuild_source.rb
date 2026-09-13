module GlobalSearch
  class IndexRebuildSource
    def self.upsert_job(job) = JobIndex.upsert(job)
    def self.upsert_epic(epic) = EpicIndex.upsert(epic)
  end
end
