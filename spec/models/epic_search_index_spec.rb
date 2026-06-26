require "rails_helper"

RSpec.describe EpicSearchIndex do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:other_repo) { Factories.repository(user: other_user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "upserts an epic and finds it by title or description" do
    epic = Factories.epic(
      user: user,
      repository: repo,
      title: "Unified landing search",
      description: "Expose deployment context in global results."
    )

    described_class.upsert(epic)

    title_results = described_class.search("landing", user_id: user.id)
    description_results = described_class.search("deployment", user_id: user.id)

    expect(title_results.first).to include(epic_id: epic.id)
    expect(title_results.first[:snippet]).to include("<mark>landing</mark>")
    expect(description_results.first).to include(epic_id: epic.id)
    expect(description_results.first[:snippet]).to include("<mark>deployment</mark>")
  end

  it "replaces stale rows when the epic changes" do
    epic = Factories.epic(
      user: user,
      repository: repo,
      title: "Old searchable title",
      description: "Old searchable description"
    )

    described_class.upsert(epic)
    epic.update!(title: "New searchable title", description: "New searchable description")
    described_class.upsert(epic)

    expect(described_class.search("old", user_id: user.id)).to be_empty
    expect(described_class.search("new", user_id: user.id).map { |row| row[:epic_id] }).to eq([ epic.id ])
  end

  it "scopes results to the requested user" do
    own_epic = Factories.epic(user: user, repository: repo, title: "wal search scope")
    other_epic = Factories.epic(user: other_user, repository: other_repo, title: "wal search scope")
    described_class.upsert(own_epic)
    described_class.upsert(other_epic)

    results = described_class.search("scope", user_id: user.id)

    expect(results.map { |row| row[:epic_id] }).to eq([ own_epic.id ])
  end

  it "orders more relevant matches first using BM25 rank" do
    weaker = Factories.epic(user: user, repository: repo, title: "needle deployment")
    stronger = Factories.epic(user: user, repository: repo, title: "needle needle needle deployment")
    described_class.upsert(weaker)
    described_class.upsert(stronger)

    results = described_class.search("needle", user_id: user.id)

    expect(results.map { |row| row[:epic_id] }).to start_with(stronger.id, weaker.id)
    expect(results.first[:rank]).to be < results.second[:rank]
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
