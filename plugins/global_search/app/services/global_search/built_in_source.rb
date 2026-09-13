module GlobalSearch
  class BuiltInSource
    def self.upsert_job(job) = JobIndex.upsert(job)

    def self.upsert_epic(epic) = EpicIndex.upsert(epic)

    def self.index_job(job) = upsert_job(job)
    def self.index_epic(epic) = upsert_epic(epic)
  end
end
