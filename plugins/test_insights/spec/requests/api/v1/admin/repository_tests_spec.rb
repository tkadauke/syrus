require "rails_helper"

RSpec.describe "Admin API repository tests", type: :request do
  # `let!` -- the first User created anywhere in a spec run is
  # auto-promoted to admin (User#promote_first_user_to_admin), so `admin`
  # must exist before any other user in this file to keep `non_admin`
  # actually non-admin.
  let!(:admin)       { Factories.user(admin: true) }
  let(:admin_token)  { admin.generate_api_token! }
  let(:non_admin)    { Factories.user }
  let(:non_admin_token) { non_admin.generate_api_token! }
  let(:repo_owner)   { Factories.user }
  let(:repo)         { Factories.repository(user: repo_owner) }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  def make_test_run
    @test_run ||= begin
      run = Factories.job(user: repo_owner, repository: repo).initial_run
      TestInsights::TestRun.create!(
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
  end

  def make_identity(name:, suite_name: "Suite", file_path: nil)
    TestInsights::TestIdentity.create!(
      repository: repo,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name,
      file_path: file_path
    )
  end

  def make_case(identity:, status:, created_at: Time.current, duration_ms: 125)
    test_case = TestInsights::TestCase.create!(
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

  describe "auth" do
    it "401s without a token" do
      get "/api/v1/admin/repositories/#{repo.id}/tests"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for a non-admin token even when they own the repository" do
      repo.update!(user: non_admin)

      get "/api/v1/admin/repositories/#{repo.id}/tests", headers: auth(non_admin_token)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/admin/repositories/:repository_id/tests" do
    it "lists failing tests filtered by state, without needing a session cookie" do
      failing = make_identity(name: "fails recently")
      make_identity(name: "passes quickly").tap { |identity| make_case(identity: identity, status: "passed") }
      make_case(identity: failing, status: "failed", created_at: 3.minutes.ago)

      get "/api/v1/admin/repositories/#{repo.id}/tests", params: { state: "failing" }, headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("filter")).to eq("failing")
      expect(body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "fails recently" ])
    end

    it "sorts by failure rate" do
      low = make_identity(name: "rarely fails")
      make_case(identity: low, status: "passed", created_at: 4.minutes.ago)
      make_case(identity: low, status: "passed", created_at: 3.minutes.ago)
      make_case(identity: low, status: "failed", created_at: 2.minutes.ago)
      high = make_identity(name: "often fails")
      make_case(identity: high, status: "passed", created_at: 4.minutes.ago)
      make_case(identity: high, status: "failed", created_at: 3.minutes.ago)
      make_case(identity: high, status: "failed", created_at: 2.minutes.ago)

      get "/api/v1/admin/repositories/#{repo.id}/tests",
        params: { state: "flaky", sort: "failure_rate", direction: "desc" }, headers: auth

      expect(response).to have_http_status(:ok)
      names = parse_body.fetch("tests").map { |test| test.fetch("name") }
      expect(names.first).to eq("often fails")
    end

    it "sorts by last recorded runtime" do
      slow = make_identity(name: "slow test")
      make_case(identity: slow, status: "passed", duration_ms: 5_000)
      fast = make_identity(name: "fast test")
      make_case(identity: fast, status: "passed", duration_ms: 10)

      get "/api/v1/admin/repositories/#{repo.id}/tests",
        params: { sort: "last_duration", direction: "desc" }, headers: auth

      expect(response).to have_http_status(:ok)
      names = parse_body.fetch("tests").map { |test| test.fetch("name") }
      expect(names.first).to eq("slow test")
    end

    it "works for a repository the admin does not own" do
      make_case(identity: make_identity(name: "owned by someone else"), status: "passed")

      get "/api/v1/admin/repositories/#{repo.id}/tests", headers: auth

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/admin/repositories/:repository_id/tests/:id" do
    it "returns one test's execution history" do
      identity = make_identity(name: "tracks history", suite_name: "HistorySpec")
      failed = make_case(identity: identity, status: "failed", duration_ms: 250, created_at: 2.minutes.ago)
      passed = make_case(identity: identity, status: "passed", duration_ms: 100, created_at: 1.minute.ago)

      get "/api/v1/admin/repositories/#{repo.id}/tests/#{identity.id}", headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("test", "name")).to eq("tracks history")
      expect(body.fetch("history").map { |row| row.dig("test_case", "id") }).to eq([ passed.id, failed.id ])
    end

    it "404s for a test that belongs to a different repository" do
      identity = make_identity(name: "wrong repo")
      other_repo = Factories.repository(user: repo_owner)

      get "/api/v1/admin/repositories/#{other_repo.id}/tests/#{identity.id}", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "plugin_disabled" do
    it "answers plugin_disabled for both endpoints when test_insights is disabled" do
      PluginRecord.find_by!(name: "test_insights").update!(enabled: false)
      identity = make_identity(name: "disabled check")

      get "/api/v1/admin/repositories/#{repo.id}/tests", headers: auth
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

      get "/api/v1/admin/repositories/#{repo.id}/tests/#{identity.id}", headers: auth
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end
  end
end
