module GlobalSearch
  class BuiltInSource
    def self.index_job(job)
      JobIndex.upsert(job)
    end

    def self.index_epic(epic)
      EpicIndex.upsert(epic)
    end
  end
end
