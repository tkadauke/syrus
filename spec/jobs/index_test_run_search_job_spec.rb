require "rails_helper"

RSpec.describe IndexTestRunSearchJob do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repo) }
  let(:run) { Run.create!(job: job, user: user, trigger_kind: "initial") }
  let(:test_run) do
    TestRun.create!(
      run: run,
      repository: repo,
      grader_name: "rspec",
      total_count: 2,
      passed_count: 2,
      failed_count: 0,
      skipped_count: 0,
      error_count: 0
    )
  end

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "indexes every durable test identity for a test run in batches" do
    first_identity = TestIdentity.create!(repository: repo, fingerprint: "first", name: "first searchable", suite_name: "Suite")
    second_identity = TestIdentity.create!(repository: repo, fingerprint: "second", name: "second searchable", suite_name: "Suite")
    TestCase.create!(test_run: test_run, repository: repo, test_identity: first_identity, name: "first searchable", suite_name: "Suite", status: "passed")
    TestCase.create!(test_run: test_run, repository: repo, test_identity: second_identity, name: "second searchable", suite_name: "Suite", status: "passed")

    stub_const("#{described_class}::BATCH_SIZE", 1)

    expect {
      described_class.perform_now(test_run.id)
    }.to change { indexed_test_identity_ids }.from([]).to([ first_identity.id, second_identity.id ])
  end

  it "ignores missing test runs" do
    expect {
      described_class.perform_now(123_456)
    }.not_to change { indexed_test_identity_ids }
  end

  def indexed_test_identity_ids
    SearchRecord.connection.select_values("SELECT test_identity_id FROM test_identity_fts ORDER BY test_identity_id").map(&:to_i)
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_identity_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE test_identity_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_identity_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        last_status UNINDEXED,
        last_seen_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
