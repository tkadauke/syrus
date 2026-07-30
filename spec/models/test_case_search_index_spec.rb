require "rails_helper"

RSpec.describe TestCaseSearchIndex do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:other_repo) { Factories.repository(user: other_user) }
  let(:job) { Factories.job_record(user: user, repository: repo) }
  let(:run) { Run.create!(job: job, user: user, trigger_kind: "initial") }
  let(:test_run) do
    TestRun.create!(
      run: run,
      repository: repo,
      grader_name: "rspec",
      total_count: 1,
      passed_count: 1,
      failed_count: 0,
      skipped_count: 0,
      error_count: 0
    )
  end

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "upserts a test case and finds it by name, suite_name, or file_path" do
    test_case = TestCase.create!(
      test_run: test_run,
      repository: repo,
      name: "LoginService validates credentials",
      suite_name: "AuthSpec",
      file_path: "spec/services/login_service_spec.rb",
      status: "passed"
    )

    described_class.upsert(test_case)

    name_results = described_class.search("LoginService", user_id: user.id)
    suite_results = described_class.search("AuthSpec", user_id: user.id)
    path_results = described_class.search("login_service_spec", user_id: user.id)

    expect(name_results.first).to include(test_case_id: test_case.id)
    expect(name_results.first[:snippet]).to include("<mark>")
    expect(suite_results.first).to include(test_case_id: test_case.id)
    expect(path_results.first).to include(test_case_id: test_case.id)
  end

  it "replaces stale rows when the test case changes" do
    test_case = TestCase.create!(
      test_run: test_run,
      repository: repo,
      name: "OldTestName passes",
      suite_name: "OldSuite",
      status: "passed"
    )

    described_class.upsert(test_case)
    test_case.update!(name: "NewTestName passes", suite_name: "NewSuite")
    described_class.upsert(test_case)

    expect(described_class.search("OldTestName", user_id: user.id)).to be_empty
    expect(described_class.search("NewTestName", user_id: user.id).map { |row| row[:test_case_id] }).to eq([ test_case.id ])
  end

  it "scopes results to the requested user" do
    own_test = TestCase.create!(
      test_run: test_run,
      repository: repo,
      name: "shared search term passes",
      suite_name: "Suite",
      status: "passed"
    )

    other_run = Run.create!(job: Factories.job_record(user: other_user, repository: other_repo), user: other_user, trigger_kind: "initial")
    other_test_run = TestRun.create!(run: other_run, repository: other_repo, grader_name: "rspec", total_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0)
    other_test = TestCase.create!(
      test_run: other_test_run,
      repository: other_repo,
      name: "shared search term passes",
      suite_name: "Suite",
      status: "passed"
    )

    described_class.upsert(own_test)
    described_class.upsert(other_test)

    results = described_class.search("shared", user_id: user.id)

    expect(results.map { |row| row[:test_case_id] }).to eq([ own_test.id ])
  end

  it "orders more relevant matches first using BM25 rank" do
    weaker = TestCase.create!(test_run: test_run, repository: repo, name: "needle test passes", suite_name: "Suite", status: "passed")
    stronger = TestCase.create!(test_run: test_run, repository: repo, name: "needle needle needle test passes", suite_name: "Suite", status: "passed")

    described_class.upsert(weaker)
    described_class.upsert(stronger)

    results = described_class.search("needle", user_id: user.id)

    expect(results.map { |row| row[:test_case_id] }).to start_with(stronger.id, weaker.id)
    expect(results.first[:rank]).to be < results.second[:rank]
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
