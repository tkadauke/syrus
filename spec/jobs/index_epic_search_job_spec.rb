require "rails_helper"

RSpec.describe IndexEpicSearchJob do
  let(:repo) { Factories.repository }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "upserts an existing epic into the search index" do
    epic = Factories.epic(repository: repo, title: "Find this later.")

    expect {
      described_class.perform_now(epic.id)
    }.to change { indexed_epic_ids }.from([]).to([ epic.id ])
  end

  it "skips missing epics" do
    expect {
      described_class.perform_now(-1)
    }.not_to change { indexed_epic_ids }
  end

  def indexed_epic_ids
    SearchRecord.connection.select_values("SELECT epic_id FROM epic_fts ORDER BY epic_id").map(&:to_i)
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS epic_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE epic_fts
      USING fts5(
        title,
        description,
        epic_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
