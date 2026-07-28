require "rails_helper"

RSpec.describe "App API job priority", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repo, priority: "medium") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  describe "PATCH /api/v1/app/jobs/:job_id/priority" do
    it "updates the priority to a valid value and returns the updated job payload" do
      patch "/api/v1/app/jobs/#{job.id}/priority", params: { priority: "high" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload.priority).to eq("high")
      body = parse_body
      expect(body["job"]["priority"]).to eq("high")
      expect(body.dig("paths", "app_priority_path")).to eq("/api/v1/app/jobs/#{job.id}/priority")
    end

    it "accepts the urgent priority value" do
      patch "/api/v1/app/jobs/#{job.id}/priority", params: { priority: "urgent" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload.priority).to eq("urgent")
      expect(parse_body["job"]["priority"]).to eq("urgent")
    end

    it "rejects an invalid priority value with 422" do
      patch "/api/v1/app/jobs/#{job.id}/priority", params: { priority: "critical" }, as: :json

      expect(response).to have_http_status(422)
      expect(parse_body.dig("error", "code")).to eq("invalid_priority")
    end

    it "rejects a blank priority value with 422" do
      patch "/api/v1/app/jobs/#{job.id}/priority", params: { priority: "" }, as: :json

      expect(response).to have_http_status(422)
      expect(parse_body.dig("error", "code")).to eq("invalid_priority")
    end

    it "returns 404 when the job belongs to another user" do
      other_job = Factories.job_record(priority: "medium")

      patch "/api/v1/app/jobs/#{other_job.id}/priority", params: { priority: "high" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
