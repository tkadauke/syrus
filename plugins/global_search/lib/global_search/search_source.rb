module GlobalSearch
  class SearchSource
    def self.indexes_jobs? = true
    def self.indexes_epics? = true

    def self.index_job(job) = JobIndex.upsert(job)
    def self.index_epic(epic) = EpicIndex.upsert(epic)
  end
end
