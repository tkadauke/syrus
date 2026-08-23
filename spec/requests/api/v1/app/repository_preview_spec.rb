require "rails_helper"

RSpec.describe "App API repository preview", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def preview_path(repository) = "/api/v1/app/repositories/#{repository.id}/preview"
  def preview_logs_path(repository) = "/api/v1/app/repositories/#{repository.id}/preview/logs"

  def create_preview_env(repository, **attrs)
    PreviewEnvironment.create!({ repository: repository, state: "starting" }.merge(attrs))
  end

  describe "GET /api/v1/app/repositories/:repository_id/preview" do
    it "returns null preview when none exists" do
      get preview_path(repo), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("preview" => nil)
    end

    it "returns the most recent preview environment" do
      env = create_preview_env(repo, state: "running",
                                expires_at: 10.minutes.from_now,
                                last_activity_at: Time.current)

      get preview_path(repo), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["preview"]).to include(
        "id" => env.id,
        "state" => "running",
        "error_message" => nil
      )
    end

    it "includes the preview URL when running, keyed on the environment id" do
      env = create_preview_env(repo, state: "running", expires_at: 10.minutes.from_now)

      get preview_path(repo), as: :json

      expect(parse_body.dig("preview", "url")).to eq("http://preview-#{env.id}.lvh.me")
    end

    it "omits the URL when not running" do
      create_preview_env(repo, state: "starting")

      get preview_path(repo), as: :json

      expect(parse_body.dig("preview", "url")).to be_nil
    end

    it "does not see a job-scoped preview environment for the same repository" do
      job = Factories.job_record(repository: repo)
      PreviewEnvironment.create!(job: job, state: "running", expires_at: 10.minutes.from_now)

      get preview_path(repo), as: :json

      expect(parse_body).to eq("preview" => nil)
    end

    it "does not expose another user's repository" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)

      get preview_path(other_repo), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/repositories/:repository_id/preview" do
    it "creates a repository-scoped preview environment in starting state" do
      expect {
        post preview_path(repo), as: :json
      }.to change { repo.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(parse_body["preview"]).to include("state" => "starting")
      expect(parse_body["message"]).to eq("Preview environment starting.")
    end

    it "leaves job_id nil on the created environment" do
      post preview_path(repo), as: :json

      expect(PreviewEnvironment.find(parse_body.dig("preview", "id")).job_id).to be_nil
    end

    it "rejects creation for an archived repository" do
      repo.archive!

      expect {
        post preview_path(repo), as: :json
      }.not_to change { repo.preview_environments.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "rejects creation when an active preview already exists" do
      create_preview_env(repo, state: "running", expires_at: 10.minutes.from_now)

      expect {
        post preview_path(repo), as: :json
      }.not_to change { repo.preview_environments.count }

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("conflict")
    end

    it "allows creation after the previous preview has stopped" do
      create_preview_env(repo, state: "stopped")

      expect {
        post preview_path(repo), as: :json
      }.to change { repo.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "does not conflict with an active job-scoped preview for the same repository" do
      job = Factories.job_record(repository: repo)
      PreviewEnvironment.create!(job: job, state: "running", expires_at: 10.minutes.from_now)

      expect {
        post preview_path(repo), as: :json
      }.to change { repo.preview_environments.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "does not expose another user's repository" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)

      post preview_path(other_repo), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/app/repositories/:repository_id/preview/logs" do
    def stub_control_endpoint(env, lines:, status: 200, body: nil)
      stub_request(:get, "http://10.0.0.5:#{PreviewControlServer::PORT}/environments/#{env.id}/logs?lines=#{lines}")
        .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body || "{}")
    end

    it "returns tailed preview logs fetched through the preview control endpoint" do
      env = create_preview_env(repo, state: "running", internal_host: "10.0.0.5", expires_at: 10.minutes.from_now)
      stub = stub_control_endpoint(env, lines: "2", body: {
        logs: [ { path: "log/development.log", content: "second\nthird", missing: false } ]
      }.to_json)

      get "#{preview_logs_path(repo)}?lines=2", as: :json

      expect(stub).to have_been_requested
      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("preview", "state")).to eq("running")
      expect(parse_body["logs"]).to include(
        a_hash_including("path" => "log/development.log", "content" => "second\nthird", "missing" => false)
      )
    end

    it "returns not_found when no preview environment exists" do
      get preview_logs_path(repo), as: :json

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "DELETE /api/v1/app/repositories/:repository_id/preview" do
    it "transitions a running preview to stopping" do
      env = create_preview_env(repo, state: "running", expires_at: 10.minutes.from_now)

      delete preview_path(repo), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["preview"]).to include("state" => "stopping")
      expect(parse_body["message"]).to eq("Preview environment stopping.")
      expect(env.reload.state).to eq("stopping")
    end

    it "returns not_found when no active preview exists" do
      create_preview_env(repo, state: "stopped")

      delete preview_path(repo), as: :json

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end

    it "does not expose another user's repository" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)

      delete preview_path(other_repo), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
