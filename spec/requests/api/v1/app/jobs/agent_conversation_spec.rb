require "rails_helper"

RSpec.describe "App API job agent_conversation", type: :request do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: owner, repository: repo) }
  let(:outsider) { Factories.user }

  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/app/jobs/:id/agent_conversation" do
    it "returns the node/edge graph for a job the requester can see" do
      workflow = Workflow.create!(job: job, user: owner, trigger_kind: "initial", agent_provider: "claude")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded")
      run = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", agent_summary: "Did the thing")

      sign_in_as(owner)

      get "/api/v1/app/jobs/#{job.id}/agent_conversation"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["job_id"]).to eq(job.id)
      node = body["nodes"].find { |n| n["id"] == "agent_session-#{run.id}" }
      expect(node).to include("kind" => "agent_session", "summary" => "Did the thing")
    end

    it "is authorized the same way as the job detail endpoint (404 for a user with no repository access)" do
      sign_in_as(outsider)

      get "/api/v1/app/jobs/#{job.id}/agent_conversation"

      expect(response).to have_http_status(:not_found)
    end
  end
end
