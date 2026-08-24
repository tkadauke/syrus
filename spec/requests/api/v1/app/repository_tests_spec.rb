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
    it "returns interesting failing, flaky, and slow tests by default" do
      failing = make_identity(name: "fails recently")
      flaky = make_identity(name: "flakes recently")
      slow = make_identity(name: "runs slowly")
      passing = make_identity(name: "passes quickly")
      make_case(identity: failing, status: "failed", created_at: 3.minutes.ago)
      make_case(identity: flaky, status: "failed", created_at: 2.minutes.ago)
      make_case(identity: flaky, status: "passed", created_at: 1.minute.ago)
      make_case(identity: slow, status: "passed", duration_ms: 4_500)
      make_case(identity: passing, status: "passed", duration_ms: 50)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
      tests_by_name = parse_body.fetch("tests").index_by { |test| test.fetch("name") }
      expect(tests_by_name.keys).to contain_exactly("flakes recently", "fails recently", "runs slowly")
      expect(tests_by_name.fetch("flakes recently").fetch("interesting_reasons")).to include("failing", "flaky")
      expect(tests_by_name.fetch("runs slowly").fetch("interesting_reasons")).to include("slow")
    end

    it "searches durable tests by name" do
      make_case(identity: make_identity(name: "needle browser test"), status: "passed")

      get "/api/v1/app/repositories/#{repo.id}/tests", params: { query: "needle" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "needle browser test" ])
    end
  end

  describe "GET /api/v1/app/repositories/:repository_id/tests/:id" do
    it "returns history newest first with run links, duration points, and pagination metadata" do
      identity = make_identity(name: "tracks history", suite_name: "HistorySpec")
      failed = make_case(identity: identity, status: "failed", duration_ms: 250, created_at: 2.minutes.ago)
      passed = make_case(identity: identity, status: "passed", duration_ms: 100, created_at: 1.minute.ago)

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("test", "name")).to eq("tracks history")
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq([ passed.id, failed.id ])
      expect(body.fetch("history").last.dig("run", "path")).to include("#run-")
      expect(body.fetch("duration_points").map { |row| row.fetch("duration_ms") }).to eq([ 250, 100 ])
      expect(body.fetch("pagination")).to eq(
        "page" => 1, "per_page" => Api::V1::App::RepositoryTestsController::PER_PAGE, "total" => 2, "total_pages" => 1
      )
    end

    it "paginates history across pages" do
      identity = make_identity(name: "paginated history", suite_name: "HistorySpec")
      cases = (1..25).map { |i| make_case(identity: identity, status: "passed", created_at: i.minutes.ago) }

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}", params: { page: 1, per_page: 10 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq(cases.first(10).map(&:id))
      expect(body.fetch("pagination")).to eq("page" => 1, "per_page" => 10, "total" => 25, "total_pages" => 3)

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}", params: { page: 3, per_page: 10 }

      body = parse_body
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq(cases[20..24].map(&:id))
      expect(body.fetch("pagination")).to eq("page" => 3, "per_page" => 10, "total" => 25, "total_pages" => 3)
    end
  end

  describe "repository access" do
    it "allows a RepositoryMembership collaborator to view the tests tab" do
      collaborator = Factories.user(email_address: "collaborator@example.com")
      repo.repository_memberships.create!(user: collaborator, role: "read")
      sign_in_as(collaborator)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
    end

    it "404s for a user who is neither the owner nor a member" do
      unrelated_user = Factories.user(email_address: "unrelated@example.com")
      sign_in_as(unrelated_user)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:not_found)
    end
  end
end
