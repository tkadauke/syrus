require "rails_helper"

RSpec.describe "Global Search versioned sources", type: :service do
  before do
    SyrusSearchDatabaseTasks.prepare!
    SearchRecord.connection.execute("DELETE FROM search_index_metadata")
  end

  [ GlobalSearch::JobSearchSource, GlobalSearch::EpicSearchSource ].each do |source|
    it "initializes #{source.search_database_rebuild_key} without rebuilding an existing compatible table" do
      source.search_database_initialize_content_version!

      expect(source.current_content_version).to eq(source.search_database_content_version)
      expect(source.search_database_tables).not_to be_empty
    end
  end
end
