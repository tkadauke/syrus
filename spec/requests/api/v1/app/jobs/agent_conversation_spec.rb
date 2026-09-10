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
      expect(body["selected_workflow_id"]).to eq(workflow.id)
      expect(body["workflows"]).to contain_exactly(
        include("id" => workflow.id, "slug" => workflow.slug, "trigger_kind" => "initial", "trigger_label" => Workflow::TriggerKind.label_for("initial"))
      )
      node = body["nodes"].find { |n| n["id"] == "agent_session-#{run.id}" }
      expect(node).to include("kind" => "agent_session", "summary" => "Did the thing")
    end

    it "returns the requested workflow graph without mixing in other workflow nodes" do
      older_workflow = Workflow.create!(job: job, user: owner, trigger_kind: "initial", agent_provider: "claude")
      older_step = Step.create!(workflow: older_workflow, kind: "implement", position: 0, state: "succeeded")
      older_run = Run.create!(job: job, step: older_step, trigger_kind: "initial", agent_provider: "claude", agent_summary: "Older run")
      newer_workflow = Workflow.create!(job: job, user: owner, trigger_kind: "retry", agent_provider: "claude")
      newer_step = Step.create!(workflow: newer_workflow, kind: "implement", position: 0, state: "succeeded")
      newer_run = Run.create!(job: job, step: newer_step, trigger_kind: "retry", agent_provider: "claude", agent_summary: "Newer run")

      sign_in_as(owner)

      get "/api/v1/app/jobs/#{job.id}/agent_conversation", params: { workflow_id: older_workflow.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["selected_workflow_id"]).to eq(older_workflow.id)
      expect(body["workflows"].map { |workflow| workflow["id"] }).to eq([ newer_workflow.id, older_workflow.id ])
      expect(body["nodes"].map { |node| node["id"] }).to contain_exactly("agent_session-#{older_run.id}")
      expect(body["nodes"].map { |node| node["id"] }).not_to include("agent_session-#{newer_run.id}")
    end

    it "is authorized the same way as the job detail endpoint (404 for a user with no repository access)" do
      sign_in_as(outsider)

      get "/api/v1/app/jobs/#{job.id}/agent_conversation"

      expect(response).to have_http_status(:not_found)
    end
  end
end
