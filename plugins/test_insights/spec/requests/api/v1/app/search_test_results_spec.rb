require "rails_helper"

# The plugin registers `test_case` as a :search_source, so unified search can
# return test identities. Core's search spec stays plugin-agnostic; this is
# the plugin's own end of that contract.
RSpec.describe "App API unified search: test results", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
    sign_in_as(user)
  end

  def results
    JSON.parse(response.body).fetch("results")
  end

  it "returns test results with path to the repository test history" do
    job = Factories.job_record(user: user, repository: repository)
    run = Run.create!(job: job, user: user, trigger_kind: "initial")
    test_run = TestInsights::TestRun.create!(
      run: run,
      repository: repository,
      grader_name: "rspec",
      total_count: 1,
      passed_count: 0,
      failed_count: 1,
      skipped_count: 0,
      error_count: 0
    )
    test_identity = TestInsights::TestIdentity.create!(
      repository: repository,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: "AuthSpec", name: "LoginService validates credentials uniquely"),
      name: "LoginService validates credentials uniquely",
      suite_name: "AuthSpec",
      file_path: "spec/services/login_service_spec.rb",
      last_status: "failed",
      last_seen_at: Time.current
    )
    test_case = TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repository,
      test_identity: test_identity,
      name: "LoginService validates credentials uniquely",
      suite_name: "AuthSpec",
      file_path: "spec/services/login_service_spec.rb",
      status: "failed"
    )
    TestInsights::SearchIndex.upsert(test_identity)

    get "/api/v1/app/search", params: { query: "LoginService", types: [ "test_case" ] }

    expect(response).to have_http_status(:ok)
    expect(results.length).to eq(1)
    expect(results.first).to include(
      "type" => "test_case",
      "id" => test_identity.id,
      "title" => "LoginService validates credentials uniquely",
      "suite_name" => "AuthSpec",
      "file_path" => "spec/services/login_service_spec.rb",
      "state" => "failed",
      "path" => "/repositories/#{repository.id}/plugin/tests?test_id=#{test_identity.id}",
      "repository_slug" => "acme/widgets"
    )
    expect(results.first.fetch("snippet")).to include("<mark>")
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS epic_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_identity_fts")
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
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
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
