require "rails_helper"

RSpec.describe "App API job preview", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def preview_path(job_record) = "/api/v1/app/jobs/#{job_record.id}/preview"
  def preview_logs_path(job_record) = "/api/v1/app/jobs/#{job_record.id}/preview/logs"

  def create_preview_env(job_record, **attrs)
    PreviewEnvironment.create!({ job: job_record, state: "starting" }.merge(attrs))
  end

  describe "GET /api/v1/app/jobs/:job_id/preview" do
    it "returns null preview when none exists" do
      get preview_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("preview" => nil)
    end

    it "returns the most recent preview environment" do
      env = create_preview_env(job, state: "running",
                                expires_at: 10.minutes.from_now,
                                last_activity_at: Time.current)

      get preview_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["preview"]).to include(
        "id" => env.id,
        "state" => "running",
        "error_message" => nil
      )
    end

    it "includes the preview URL when running" do
      create_preview_env(job, state: "running", expires_at: 10.minutes.from_now)

      get preview_path(job), as: :json

      expect(parse_body.dig("preview", "url")).to match(/http:\/\/preview-#{job.id}\./)
    end

    it "omits the URL when not running" do
      create_preview_env(job, state: "starting")

      get preview_path(job), as: :json

      expect(parse_body.dig("preview", "url")).to be_nil
    end

    it "returns the error_message for failed environments" do
      create_preview_env(job, state: "failed", error_message: "No preview provider found.")

      get preview_path(job), as: :json

      expect(parse_body.dig("preview", "error_message")).to eq("No preview provider found.")
    end

    it "does not expose another user's job" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo)

      get preview_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/preview" do
    it "creates a preview environment in starting state for an implemented job" do
      job.update_columns(state: "implemented")

      expect {
        post preview_path(job), as: :json
      }.to change { job.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(parse_body["preview"]).to include("state" => "starting")
      expect(parse_body["message"]).to eq("Preview environment starting.")
    end

    it "creates a preview environment for an approved job" do
      job.update_columns(state: "approved")

      expect {
        post preview_path(job), as: :json
      }.to change { job.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "creates a preview environment for a landing job" do
      job.update_columns(state: "landing")

      expect {
        post preview_path(job), as: :json
      }.to change { job.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "rejects jobs that are not implemented, approved, or landing" do
      job.update_columns(state: "open")

      expect {
        post preview_path(job), as: :json
      }.not_to change { job.preview_environments.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
      expect(parse_body.dig("error", "message")).to include("implemented, approved, or landing")
    end

    it "rejects creation when an active preview already exists" do
      create_preview_env(job, state: "running", expires_at: 10.minutes.from_now)
      job.update_columns(state: "implemented")

      expect {
        post preview_path(job), as: :json
      }.not_to change { job.preview_environments.count }

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("conflict")
    end

    it "allows creation after the previous preview has stopped" do
      create_preview_env(job, state: "stopped")
      job.update_columns(state: "implemented")

      expect {
        post preview_path(job), as: :json
      }.to change { job.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "does not expose another user's job" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo)

      post preview_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/app/jobs/:job_id/preview/logs" do
    def stub_control_endpoint(env, lines:, status: 200, body: nil)
      stub_request(:get, "http://10.0.0.5:#{PreviewControlServer::PORT}/environments/#{env.id}/logs?lines=#{lines}")
        .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body || "{}")
    end

    it "returns tailed preview logs fetched through the preview control endpoint" do
      env = create_preview_env(job, state: "running", internal_host: "10.0.0.5", expires_at: 10.minutes.from_now)
      stub = stub_control_endpoint(env, lines: "2", body: {
        logs: [ { path: "log/development.log", content: "second\nthird", missing: false } ]
      }.to_json)

      get "#{preview_logs_path(job)}?lines=2", as: :json

      expect(stub).to have_been_requested
      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("preview", "state")).to eq("running")
      expect(parse_body["logs"]).to include(
        a_hash_including("path" => "log/development.log", "content" => "second\nthird", "missing" => false)
      )
    end

    it "returns service_unavailable when the preview control endpoint is unreachable" do
      env = create_preview_env(job, state: "running", internal_host: "10.0.0.5", expires_at: 10.minutes.from_now)
      stub_request(:get, "http://10.0.0.5:#{PreviewControlServer::PORT}/environments/#{env.id}/logs?lines=120")
        .to_timeout

      get preview_logs_path(job), as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(parse_body.dig("error", "code")).to eq("preview_logs_unavailable")
    end

    it "returns service_unavailable when the environment has no internal host recorded yet" do
      create_preview_env(job, state: "starting")

      get preview_logs_path(job), as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(parse_body.dig("error", "code")).to eq("preview_logs_unavailable")
    end

    it "returns not_found when no preview environment exists" do
      get preview_logs_path(job), as: :json

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end

    it "does not expose another user's preview logs" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo)
      create_preview_env(other_job, state: "running", internal_host: "10.0.0.5")

      get preview_logs_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/app/jobs/:job_id/preview" do
    it "transitions a running preview to stopping" do
      env = create_preview_env(job, state: "running", expires_at: 10.minutes.from_now)

      delete preview_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["preview"]).to include("state" => "stopping")
      expect(parse_body["message"]).to eq("Preview environment stopping.")
      expect(env.reload.state).to eq("stopping")
    end

    it "transitions a starting preview to stopping" do
      env = create_preview_env(job, state: "starting")

      delete preview_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(env.reload.state).to eq("stopping")
    end

    it "returns not_found when no active preview exists" do
      create_preview_env(job, state: "stopped")

      delete preview_path(job), as: :json

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end

    it "returns not_found when no preview exists at all" do
      delete preview_path(job), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "does not expose another user's job" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo)

      delete preview_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
