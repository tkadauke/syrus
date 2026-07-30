require "rails_helper"

RSpec.describe "App API repository flaky tests", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def make_test_run(run: nil, grader_name: "rspec")
    run ||= Factories.job(user: user, repository: repo).initial_run
    TestRun.create!(
      run: run, repository: repo, grader_name: grader_name,
      total_count: 0, passed_count: 0, failed_count: 0, skipped_count: 0, error_count: 0
    )
  end

  def make_test_case(test_run:, name: "it works", suite_name: "MySpec", status: "passed", duration_ms: nil)
    TestCase.create!(
      test_run: test_run, repository: repo,
      name: name, suite_name: suite_name, status: status, duration_ms: duration_ms
    )
  end

  describe "GET /api/v1/app/repositories/:repository_id/flaky_tests" do
    it "returns 401 when signed out" do
      delete "/session"
      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for a repository belonging to another user" do
      other_repo = Factories.repository(user: Factories.user)

      get "/api/v1/app/repositories/#{other_repo.id}/flaky_tests"

      expect(response).to have_http_status(:not_found)
    end

    it "returns empty tests array when no test cases exist" do
      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["repository_id"]).to eq(repo.id)
      expect(body["tests"]).to eq([])
    end

    it "returns only flaky tests (mixed pass/fail history)" do
      tr = make_test_run

      # Flaky: has both passes and failures
      make_test_case(test_run: tr, name: "flaky test", status: "passed")
      make_test_case(test_run: tr, name: "flaky test", status: "failed")

      # Stable passing: never failed
      make_test_case(test_run: tr, name: "stable test", status: "passed")
      make_test_case(test_run: tr, name: "stable test", status: "passed")

      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"

      body = parse_body
      expect(body["tests"].size).to eq(1)
      expect(body["tests"].first["name"]).to eq("flaky test")
    end

    it "returns expected fields for each flaky test" do
      tr = make_test_run

      make_test_case(test_run: tr, name: "spec", suite_name: "FooSpec", status: "failed", duration_ms: 100)
      make_test_case(test_run: tr, name: "spec", suite_name: "FooSpec", status: "passed", duration_ms: 200)

      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"

      test = parse_body["tests"].first
      expect(test["name"]).to eq("spec")
      expect(test["suite_name"]).to eq("FooSpec")
      expect(test["flakiness_score"]).to be_a(Float)
      expect(test["flakiness_score"]).to be_within(0.01).of(0.5)
      expect(test["failed_count"]).to eq(1)
      expect(test["total_count"]).to eq(2)
      expect(test["avg_duration_ms"]).to eq(150)
      expect(test["last_seen_at"]).not_to be_nil
    end

    it "sorts tests by flakiness_score descending" do
      tr = make_test_run

      # 3 failures / 4 runs = 0.75
      4.times.with_index { |i| make_test_case(test_run: tr, name: "very flaky", status: i < 3 ? "failed" : "passed") }
      # 1 failure / 4 runs = 0.25
      4.times.with_index { |i| make_test_case(test_run: tr, name: "slightly flaky", status: i < 1 ? "failed" : "passed") }

      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"

      names = parse_body["tests"].map { |t| t["name"] }
      expect(names).to eq(%w[very\ flaky slightly\ flaky])
    end

    it "returns the lookback value in the response" do
      get "/api/v1/app/repositories/#{repo.id}/flaky_tests"

      expect(parse_body["lookback"]).to eq(TestCase::FLAKINESS_LOOKBACK)
    end
  end
end
