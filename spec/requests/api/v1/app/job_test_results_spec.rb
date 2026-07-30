require "rails_helper"

RSpec.describe "App API job test results", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def build_test_run(run:, grader_name: "rspec", **attrs)
    TestRun.create!(
      run: run,
      repository: repo,
      grader_name: grader_name,
      total_count: attrs.fetch(:total_count, 3),
      passed_count: attrs.fetch(:passed_count, 2),
      failed_count: attrs.fetch(:failed_count, 1),
      skipped_count: attrs.fetch(:skipped_count, 0),
      error_count: attrs.fetch(:error_count, 0),
      duration_ms: attrs.fetch(:duration_ms, nil)
    )
  end

  def build_test_case(test_run:, **attrs)
    TestCase.create!(
      test_run: test_run,
      repository: repo,
      name: attrs.fetch(:name, "it does something"),
      suite_name: attrs.fetch(:suite_name, "MySpec"),
      status: attrs.fetch(:status, "passed"),
      file_path: attrs.fetch(:file_path, nil),
      duration_ms: attrs.fetch(:duration_ms, nil),
      failure_message: attrs.fetch(:failure_message, nil),
      failure_backtrace: attrs.fetch(:failure_backtrace, nil),
      output: attrs.fetch(:output, nil)
    )
  end

  describe "GET /api/v1/app/jobs/:job_id/test_results" do
    it "returns empty test_runs when no test runs exist for the job" do
      job = Factories.job(user: user, repository: repo)

      get "/api/v1/app/jobs/#{job.id}/test_results"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["job_id"]).to eq(job.id)
      expect(body["workflow_id"]).to be_nil
      expect(body["test_runs"]).to eq([])
    end

    it "returns test runs from the latest workflow that has them" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, grader_name: "rspec", total_count: 2, passed_count: 1, failed_count: 1)
      build_test_case(test_run: test_run, name: "passes", suite_name: "FooSpec", status: "passed")
      build_test_case(test_run: test_run, name: "fails", suite_name: "FooSpec", status: "failed",
                      failure_message: "expected true, got false", failure_backtrace: "spec/foo_spec.rb:10")

      get "/api/v1/app/jobs/#{job.id}/test_results"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["job_id"]).to eq(job.id)
      expect(body["workflow_id"]).to be_a(Integer)
      expect(body["test_runs"].size).to eq(1)

      tr = body["test_runs"].first
      expect(tr["grader_name"]).to eq("rspec")
      expect(tr["total_count"]).to eq(2)
      expect(tr["passed_count"]).to eq(1)
      expect(tr["failed_count"]).to eq(1)

      suite = tr["suites"].first
      expect(suite["suite_name"]).to eq("FooSpec")
      expect(suite["test_cases"].size).to eq(2)

      failed_case = suite["test_cases"].find { |tc| tc["status"] == "failed" }
      expect(failed_case["failure_message"]).to eq("expected true, got false")
      expect(failed_case["failure_backtrace"]).to eq("spec/foo_spec.rb:10")
    end

    it "groups test cases by suite_name" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, total_count: 3, passed_count: 3, failed_count: 0)
      build_test_case(test_run: test_run, name: "a", suite_name: "AlphaSpec", status: "passed")
      build_test_case(test_run: test_run, name: "b", suite_name: "BetaSpec", status: "passed")
      build_test_case(test_run: test_run, name: "c", suite_name: "AlphaSpec", status: "passed")

      get "/api/v1/app/jobs/#{job.id}/test_results"

      suites = parse_body.dig("test_runs", 0, "suites")
      suite_names = suites.map { |s| s["suite_name"] }
      expect(suite_names).to match_array([ "AlphaSpec", "BetaSpec" ])

      alpha = suites.find { |s| s["suite_name"] == "AlphaSpec" }
      expect(alpha["total_count"]).to eq(2)
      expect(alpha["test_cases"].size).to eq(2)
    end

    it "returns multiple test_runs ordered by grader_name" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      build_test_run(run: run, grader_name: "rspec", total_count: 1, passed_count: 1, failed_count: 0)
      build_test_run(run: run, grader_name: "jest", total_count: 1, passed_count: 1, failed_count: 0)

      get "/api/v1/app/jobs/#{job.id}/test_results"

      grader_names = parse_body["test_runs"].map { |tr| tr["grader_name"] }
      expect(grader_names).to eq([ "jest", "rspec" ])
    end

    it "includes flakiness fields for test cases" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, total_count: 1, passed_count: 1, failed_count: 0)

      # Build history: 2 passes and 1 failure for this test
      build_test_case(test_run: test_run, name: "flaky spec", suite_name: "S", status: "passed")
      build_test_case(test_run: test_run, name: "flaky spec", suite_name: "S", status: "failed")
      build_test_case(test_run: test_run, name: "flaky spec", suite_name: "S", status: "passed")

      get "/api/v1/app/jobs/#{job.id}/test_results"

      tc = parse_body.dig("test_runs", 0, "suites", 0, "test_cases", 0)
      expect(tc["flakiness_score"]).to be_a(Float).and(be > 0).and(be < 1)
      expect(tc["flakiness_failed_count"]).to eq(1)
      expect(tc["flakiness_total_count"]).to eq(3)
      expect(tc["flakiness_run_statuses"]).to be_an(Array).and(have_attributes(size: 3))
    end

    it "returns nil flakiness fields when test has no history beyond itself" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, total_count: 1, passed_count: 1, failed_count: 0)
      build_test_case(test_run: test_run, name: "new test", suite_name: "S", status: "passed")

      # Only one record exists — score will be 0.0 (not flaky), but fields should still be present
      get "/api/v1/app/jobs/#{job.id}/test_results"

      tc = parse_body.dig("test_runs", 0, "suites", 0, "test_cases", 0)
      expect(tc).to have_key("flakiness_score")
      expect(tc).to have_key("flakiness_run_statuses")
    end

    it "returns 404 for a job belonging to another user" do
      other_user = Factories.user
      job = Factories.job(user: other_user, repository: Factories.repository(user: other_user))

      get "/api/v1/app/jobs/#{job.id}/test_results"

      expect(response).to have_http_status(:not_found)
    end

    it "returns test cases with all expected fields" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, duration_ms: 1234)
      build_test_case(
        test_run: test_run, name: "does it", suite_name: "MySpec",
        status: "failed", file_path: "spec/my_spec.rb", duration_ms: 50,
        failure_message: "oops", failure_backtrace: "line 1", output: "stdout output"
      )

      get "/api/v1/app/jobs/#{job.id}/test_results"

      tc = parse_body.dig("test_runs", 0, "suites", 0, "test_cases", 0)
      expect(tc["name"]).to eq("does it")
      expect(tc["suite_name"]).to eq("MySpec")
      expect(tc["file_path"]).to eq("spec/my_spec.rb")
      expect(tc["status"]).to eq("failed")
      expect(tc["duration_ms"]).to eq(50)
      expect(tc["failure_message"]).to eq("oops")
      expect(tc["failure_backtrace"]).to eq("line 1")
      expect(tc["output"]).to eq("stdout output")

      tr = parse_body["test_runs"].first
      expect(tr["duration_ms"]).to eq(1234)
    end
  end
end
