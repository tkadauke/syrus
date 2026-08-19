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

  it "indexes every test case for a test run in batches" do
    first = TestCase.create!(test_run: test_run, repository: repo, name: "first searchable", suite_name: "Suite", status: "passed")
    second = TestCase.create!(test_run: test_run, repository: repo, name: "second searchable", suite_name: "Suite", status: "passed")

    stub_const("#{described_class}::BATCH_SIZE", 1)

    expect {
      described_class.perform_now(test_run.id)
    }.to change { indexed_test_case_ids }.from([]).to([ first.id, second.id ])
  end

  it "ignores missing test runs" do
    expect {
      described_class.perform_now(123_456)
    }.not_to change { indexed_test_case_ids }
  end

  def indexed_test_case_ids
    SearchRecord.connection.select_values("SELECT test_case_id FROM test_case_fts ORDER BY test_case_id").map(&:to_i)
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_case_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE test_case_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_case_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        status UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
