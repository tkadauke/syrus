require "rails_helper"

RSpec.describe JobSearchIndex do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:other_repo) { Factories.repository(user: other_user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "upserts a job and finds it by title or body" do
    job = Factories.job_record(
      user: user,
      repository: repo,
      issue_number: 101,
      issue_title: "Improve landing queue search",
      issue_body: "Add the deployment checklist to searchable issue text."
    )

    described_class.upsert(job)

    title_results = described_class.search("landing", user_id: user.id)
    body_results = described_class.search("deployment", user_id: user.id)

    expect(title_results.first).to include(job_id: job.id)
    expect(title_results.first[:snippet]).to include("<mark>landing</mark>")
    expect(body_results.first).to include(job_id: job.id)
    expect(body_results.first[:snippet]).to include("<mark>deployment</mark>")
  end

  it "replaces stale rows when the job changes" do
    job = Factories.job_record(
      user: user,
      repository: repo,
      issue_title: "Old searchable title",
      issue_body: "Old searchable body"
    )

    described_class.upsert(job)
    job.update!(issue_title: "New searchable title", issue_body: "New searchable body")
    described_class.upsert(job)

    expect(described_class.search("old", user_id: user.id)).to be_empty
    expect(described_class.search("new", user_id: user.id).map { |row| row[:job_id] }).to eq([ job.id ])
  end

  it "scopes results to the requested user" do
    own_job = Factories.job_record(user: user, repository: repo, issue_title: "wal search scope")
    other_job = Factories.job_record(user: other_user, repository: other_repo, issue_title: "wal search scope")
    described_class.upsert(own_job)
    described_class.upsert(other_job)

    results = described_class.search("scope", user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to eq([ own_job.id ])
  end

  it "matches unquoted words as independent AND terms" do
    matching_job = Factories.job_record(user: user, repository: repo, issue_title: "bar release foo")
    partial_job = Factories.job_record(user: user, repository: repo, issue_title: "foo only")
    described_class.upsert(matching_job)
    described_class.upsert(partial_job)

    results = described_class.search("foo bar", user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to eq([ matching_job.id ])
  end

  it "preserves quoted phrases" do
    phrase_job = Factories.job_record(user: user, repository: repo, issue_title: "foo bar release")
    reordered_job = Factories.job_record(user: user, repository: repo, issue_title: "bar foo release")
    described_class.upsert(phrase_job)
    described_class.upsert(reordered_job)

    results = described_class.search('"foo bar"', user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to eq([ phrase_job.id ])
  end

  it "mixes independent terms with quoted phrases" do
    matching_job = Factories.job_record(user: user, repository: repo, issue_title: "foo release bar baz")
    scattered_job = Factories.job_record(user: user, repository: repo, issue_title: "foo bar release baz")
    described_class.upsert(matching_job)
    described_class.upsert(scattered_job)

    results = described_class.search('foo "bar baz"', user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to eq([ matching_job.id ])
  end

  it "treats hyphenated queries as FTS literals" do
    job = Factories.job_record(user: user, repository: repo, issue_title: "JOB-1 global search")
    described_class.upsert(job)

    results = described_class.search("JOB-1", user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to eq([ job.id ])
  end

  it "orders more relevant matches first using BM25 rank" do
    weaker = Factories.job_record(user: user, repository: repo, issue_title: "needle deployment")
    stronger = Factories.job_record(user: user, repository: repo, issue_title: "needle needle needle deployment")
    described_class.upsert(weaker)
    described_class.upsert(stronger)

    results = described_class.search("needle", user_id: user.id)

    expect(results.map { |row| row[:job_id] }).to start_with(stronger.id, weaker.id)
    expect(results.first[:rank]).to be < results.second[:rank]
  end

  it "parses FTS queries without quoting the whole search string" do
    expect(described_class.send(:parse_fts_query, 'foo "bar baz" JOB-123')).to eq('foo "bar baz" "JOB-123"')
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE job_fts
      USING fts5(
        title,
        body,
        job_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
