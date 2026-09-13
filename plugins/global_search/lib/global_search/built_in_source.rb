module GlobalSearch
  class BuiltInSource
    def self.index_job(job)
      JobIndex.upsert(job)
    end

    def self.index_epic(epic)
      EpicIndex.upsert(epic)
    end

    def self.upsert_job(job) = index_job(job)
    def self.upsert_epic(epic) = index_epic(epic)
  end
end
