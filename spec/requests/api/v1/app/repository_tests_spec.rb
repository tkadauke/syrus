require "rails_helper"

RSpec.describe "App API repository tests", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def make_test_run
    run = Factories.job(user: user, repository: repo).initial_run
    TestRun.create!(
      run: run,
      repository: repo,
      grader_name: "rspec",
      total_count: 1,
      passed_count: 0,
      failed_count: 1,
      skipped_count: 0,
      error_count: 0
    )
  end

  def make_identity(name:, suite_name: "Suite", file_path: nil)
    TestIdentity.create!(
      repository: repo,
      fingerprint: TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name,
      file_path: file_path
    )
  end

  def make_case(identity:, status:, created_at: Time.current, duration_ms: 125)
    test_case = TestCase.create!(
      test_run: make_test_run,
      repository: repo,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      file_path: identity.file_path,
      status: status,
      duration_ms: duration_ms,
      failure_message: status == "failed" ? "expected true" : nil,
      created_at: created_at,
      updated_at: created_at
    )
    identity.refresh_summary!
    test_case
  end

  describe "GET /api/v1/app/repositories/:repository_id/tests" do
    it "returns recent failing tests by default" do
      failing = make_identity(name: "fails recently")
      passing = make_identity(name: "passes recently")
      make_case(identity: failing, status: "failed")
      make_case(identity: passing, status: "passed")

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "fails recently" ])
    end

    it "searches durable tests by name" do
      make_case(identity: make_identity(name: "needle browser test"), status: "passed")

      get "/api/v1/app/repositories/#{repo.id}/tests", params: { query: "needle" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "needle browser test" ])
    end
  end

  describe "GET /api/v1/app/repositories/:repository_id/tests/:id" do
    it "returns history with run links and duration points" do
      identity = make_identity(name: "tracks history", suite_name: "HistorySpec")
      failed = make_case(identity: identity, status: "failed", duration_ms: 250, created_at: 2.minutes.ago)
      passed = make_case(identity: identity, status: "passed", duration_ms: 100, created_at: 1.minute.ago)

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("test", "name")).to eq("tracks history")
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq([ failed.id, passed.id ])
      expect(body.fetch("history").last.dig("run", "path")).to include("#run-")
      expect(body.fetch("duration_points").map { |row| row.fetch("duration_ms") }).to eq([ 250, 100 ])
    end
  end
end
