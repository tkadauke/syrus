require "rails_helper"

RSpec.describe "Admin API job test results", type: :request do
  # `let!` -- the first User created anywhere in a spec run is
  # auto-promoted to admin (User#promote_first_user_to_admin), so `admin`
  # must exist before any other user in this file to keep `non_admin`
  # actually non-admin.
  let!(:admin)      { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }
  let(:job_owner)   { Factories.user }
  let(:repo)        { Factories.repository(user: job_owner) }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  def build_test_run(run:, grader_name: "rspec", **attrs)
    TestInsights::TestRun.create!(
      run: run,
      repository: repo,
      grader_name: grader_name,
      total_count: attrs.fetch(:total_count, 3),
      passed_count: attrs.fetch(:passed_count, 2),
      failed_count: attrs.fetch(:failed_count, 1),
      skipped_count: attrs.fetch(:skipped_count, 0),
      error_count: attrs.fetch(:error_count, 0)
    )
  end

  def build_test_case(test_run:, **attrs)
    TestInsights::TestCase.create!(
      test_run: test_run,
      repository: repo,
      name: attrs.fetch(:name, "it does something"),
      suite_name: attrs.fetch(:suite_name, "MySpec"),
      status: attrs.fetch(:status, "passed"),
      duration_ms: attrs.fetch(:duration_ms, nil),
      failure_message: attrs.fetch(:failure_message, nil)
    )
  end

  describe "auth" do
    it "401s without a token" do
      job = Factories.job(user: job_owner, repository: repo)

      get "/api/v1/admin/jobs/#{job.id}/test_results"

      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for a non-admin token" do
      non_admin = Factories.user
      job = Factories.job(user: job_owner, repository: repo)

      get "/api/v1/admin/jobs/#{job.id}/test_results", headers: auth(non_admin.generate_api_token!)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/admin/jobs/:job_id/test_results" do
    it "returns the same underlying data as read_job_test_results, compact by default" do
      job = Factories.job(user: job_owner, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, total_count: 2, passed_count: 1, failed_count: 1)
      build_test_case(test_run: test_run, name: "passes", suite_name: "FooSpec", status: "passed")
      build_test_case(test_run: test_run, name: "fails", suite_name: "FooSpec", status: "failed", failure_message: "boom")

      get "/api/v1/admin/jobs/#{job.id}/test_results", headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["job_id"]).to eq(job.id)
      tr = body["test_runs"].first
      expect(tr["grader_name"]).to eq("rspec")
      expect(tr["failed_error_cases"].map { |tc| tc["name"] }).to eq([ "fails" ])
      # Compact by default -- no full suite grouping unless requested.
      expect(tr).not_to have_key("suites")
    end

    it "includes suites when explicitly requested" do
      job = Factories.job(user: job_owner, repository: repo)
      run = job.initial_run
      test_run = build_test_run(run: run, total_count: 1, passed_count: 1, failed_count: 0)
      build_test_case(test_run: test_run, name: "passes", suite_name: "FooSpec", status: "passed")

      get "/api/v1/admin/jobs/#{job.id}/test_results", params: { include_suites: true }, headers: auth

      expect(response).to have_http_status(:ok)
      suites = parse_body.dig("test_runs", 0, "suites")
      expect(suites.first.fetch("suite_name")).to eq("FooSpec")
    end

    it "accepts JOB-<id> refs and works for a job the admin does not own" do
      job = Factories.job(user: job_owner, repository: repo)

      get "/api/v1/admin/jobs/JOB-#{job.id}/test_results", headers: auth

      expect(response).to have_http_status(:ok)
      expect(parse_body["job_id"]).to eq(job.id)
    end

    it "404s for an unknown job" do
      get "/api/v1/admin/jobs/999999999/test_results", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "plugin_disabled" do
    it "answers plugin_disabled when test_insights is disabled" do
      PluginRecord.find_by!(name: "test_insights").update!(enabled: false)
      job = Factories.job(user: job_owner, repository: repo)

      get "/api/v1/admin/jobs/#{job.id}/test_results", headers: auth

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end
  end
end
