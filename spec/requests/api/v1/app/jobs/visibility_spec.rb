require "rails_helper"

RSpec.describe "App API job visibility follows repository access", type: :request do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: owner, repository: repo, issue_title: "Repair aqueduct") }
  let(:member) { Factories.user }
  let(:outsider) { Factories.user }

  def parse_body = JSON.parse(response.body)

  before do
    job
    RepositoryMembership.create!(repository: repo, user: member, role: "collaborator")
  end

  describe "read visibility (mirrors Epic.accessible_to)" do
    it "lets a repository member see another member's job on the index" do
      sign_in_as(member)

      get "/api/v1/app/jobs", params: { limit: 20 }

      expect(response).to have_http_status(:ok)
      expect(parse_body["jobs"].map { |j| j["id"] }).to include(job.id)
    end

    it "lets a repository member fetch another member's job detail" do
      sign_in_as(member)

      get "/api/v1/app/jobs/#{job.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("job", "id")).to eq(job.id)
    end

    it "does not show the job to a user with no membership on its repository" do
      sign_in_as(outsider)

      get "/api/v1/app/jobs", params: { limit: 20 }

      expect(response).to have_http_status(:ok)
      expect(parse_body["jobs"].map { |j| j["id"] }).not_to include(job.id)
    end

    it "cannot find the job by id for a user with no membership on its repository" do
      sign_in_as(outsider)

      get "/api/v1/app/jobs/#{job.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "mutation actions stay creator-or-admin-only" do
    before { sign_in_as(member) }

    it "rejects chat feedback from a repository member who does not own the job" do
      job.update!(state: "implemented")

      post "/api/v1/app/jobs/#{job.id}/chat_feedback", params: { body: "Please adjust this." }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.reload.workflows.where(trigger_kind: "chat_feedback")).to be_empty
    end

    it "rejects a priority change from a repository member who does not own the job" do
      patch "/api/v1/app/jobs/#{job.id}/priority", params: { priority: "high" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.reload.priority).not_to eq("high")
    end

    it "rejects a provider setting change from a repository member who does not own the job" do
      patch "/api/v1/app/jobs/#{job.id}/provider_setting", params: { job_provider_setting: "codex" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.reload.job_provider_setting).to eq("default")
    end

    it "still allows the owner to submit chat feedback" do
      sign_in_as(owner)
      job.update!(state: "implemented")

      post "/api/v1/app/jobs/#{job.id}/chat_feedback", params: { body: "Please adjust this." }, as: :json

      expect(response).to have_http_status(:created)
    end
  end
end
