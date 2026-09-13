module GlobalSearch
  class BuiltInSource
    TABLES = {
      "job_fts" => nil,
      "epic_fts" => nil
    }.freeze

    REBUILDERS = {
      "job_fts" => -> { Job.find_each { |job| JobIndex.upsert(job) } },
      "epic_fts" => -> { Epic.find_each { |epic| EpicIndex.upsert(epic) } }
    }.freeze

    def self.search_tables = TABLES

    def self.rebuild_search_table(table_name)
      REBUILDERS[table_name.to_s]&.call
    end
  end
end
