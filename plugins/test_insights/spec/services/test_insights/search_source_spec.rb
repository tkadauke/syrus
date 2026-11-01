require "rails_helper"

RSpec.describe TestInsights::SearchSource, type: :service do
  before do
    SyrusSearchDatabaseTasks.prepare!
    SearchRecord.connection.execute("DELETE FROM search_index_metadata")
  end

  it "publishes and initializes its entity content version" do
    described_class.search_database_initialize_content_version!

    expect(described_class.search_database_rebuild_key).to eq("test_cases")
    expect(described_class.current_content_version).to eq(described_class.search_database_content_version)
    expect(described_class.search_database_tables).to eq([ "test_identity_fts" ])
  end
end
