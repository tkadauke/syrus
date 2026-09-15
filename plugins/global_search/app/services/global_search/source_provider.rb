module GlobalSearch
  class SourceProvider
    def self.index_job(job) = JobIndex.upsert(job)

    def self.index_epic(epic) = EpicIndex.upsert(epic)
  end
end
