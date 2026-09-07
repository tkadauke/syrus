require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/agent_activity", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: Factories.user) }

  def parse_body = JSON.parse(response.body)

  describe "GET /sessions" do
    it "rejects non-admins" do
      sign_in_as(member)

      get "/api/v1/app/admin/agent_activity/sessions"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns sessions across every repository, not just ones the admin belongs to" do
      sign_in_as(admin)
      job = Factories.job_with_run(
        repository: repository,
        run_attrs: { state: "running", started_at: 2.minutes.ago }
      )

      get "/api/v1/app/admin/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to include(job.id)
    end

    it "gives each session an admin-scoped transcript_path" do
      sign_in_as(admin)
      job = Factories.job_with_run(repository: repository, run_attrs: { state: "running", started_at: 1.minute.ago })
      run = job.runs.last

      get "/api/v1/app/admin/agent_activity/sessions"

      row = parse_body.fetch("sessions").first
      expect(row.fetch("transcript_path")).to eq("/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts")
    end
  end

  describe "GET /sessions/:run_id/artifacts" do
    it "rejects non-admins" do
      sign_in_as(member)

      get "/api/v1/app/admin/agent_activity/sessions/1/artifacts"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns the transcript logs for a Run on a repository the admin doesn't otherwise belong to" do
      sign_in_as(admin)
      job = Factories.job_with_run(repository: repository, run_attrs: { state: "succeeded" })
      run = job.runs.last
      run.job_logs.create!(sequence: 1, kind: "assistant_text", chunk: "Looked at the aqueducts.")

      get "/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("job_id")).to eq(job.id)
      expect(parse_body.fetch("logs").map { |l| l["chunk"] }).to eq([ "Looked at the aqueducts." ])
    end

    it "404s for an unknown run" do
      sign_in_as(admin)

      get "/api/v1/app/admin/agent_activity/sessions/-1/artifacts"

      expect(response).to have_http_status(:not_found)
    end
  end
end
