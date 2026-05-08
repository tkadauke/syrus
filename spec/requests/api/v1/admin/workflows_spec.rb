require "rails_helper"

RSpec.describe "API: /api/v1/admin/workflows/:id/*", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:job) { Factories.job(user: admin) }
  let(:workflow) { job.workflows.last }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  describe "POST /workflows/:id/retry_step" do
    before do
      # Set up a failed second step (summarize) on the workflow.
      summarize_step = workflow.steps.find_by(kind: "summarize")
      summarize_step.runs.create!(job: job, trigger_kind: "initial",
                                  state: "failed",
                                  started_at: 1.minute.ago,
                                  finished_at: Time.current,
                                  agent_outcome: "error_max_turns")
      summarize_step.update!(state: "failed",
                             started_at: 1.minute.ago, finished_at: Time.current)
      workflow.update!(state: "failed",
                       started_at: 1.minute.ago, finished_at: Time.current)
    end

    it "401s without a token" do
      post "/api/v1/admin/workflows/#{workflow.id}/retry_step"
      expect(response).to have_http_status(:unauthorized)
    end

    it "reopens workflow + step and creates a fresh run on the failed step" do
      summarize_step = workflow.steps.find_by(kind: "summarize")
      expect {
        post "/api/v1/admin/workflows/#{workflow.id}/retry_step", headers: auth
      }.to change { summarize_step.runs.count }.by(1)

      expect(response).to be_successful
      body = parse_body
      expect(body["ok"]).to be true
      expect(body["workflow_id"]).to eq(workflow.id)
      expect(body["step_id"]).to eq(summarize_step.id)
      expect(body["new_run_id"]).to be_present

      expect(workflow.reload.state).to eq("running")
      expect(summarize_step.reload.state).to eq("queued")
    end

    it "preserves the workflow agent provider on the retry run" do
      workflow.update!(agent_provider: "codex")

      post "/api/v1/admin/workflows/#{workflow.id}/retry_step", headers: auth

      summarize_step = workflow.steps.find_by(kind: "summarize")
      expect(summarize_step.runs.order(:created_at).last.agent_provider).to eq("codex")
    end

    it "refuses when the workspace was already cleaned up" do
      workflow.update_columns(cleaned_up_at: Time.current)
      post "/api/v1/admin/workflows/#{workflow.id}/retry_step", headers: auth
      expect(response).to have_http_status(:unprocessable_entity)
      expect(parse_body.dig("error", "code")).to eq("workspace_cleaned_up")
    end

    it "refuses when the workflow isn't failed" do
      workflow.update!(state: "running", finished_at: nil)
      post "/api/v1/admin/workflows/#{workflow.id}/retry_step", headers: auth
      expect(response).to have_http_status(:unprocessable_entity)
      expect(parse_body.dig("error", "code")).to eq("workflow_not_failed")
    end
  end

  describe "POST /workflows/:id/cleanup_workspace" do
    it "stamps cleaned_up_at and returns the new value" do
      expect(workflow.cleaned_up_at).to be_nil
      post "/api/v1/admin/workflows/#{workflow.id}/cleanup_workspace", headers: auth
      expect(response).to be_successful
      body = parse_body
      expect(body["ok"]).to be true
      expect(body["cleaned_up_at"]).to be_present
      expect(workflow.reload.cleaned_up_at).to be_present
    end

    it "401s without a token" do
      post "/api/v1/admin/workflows/#{workflow.id}/cleanup_workspace"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /workflows/:id" do
    it "returns the workflow's nested state without sibling workflows from the same Job" do
      original = workflow  # materialize before adding the sibling
      sibling = Workflow.create!(job: job, trigger_kind: "rebase", state: "succeeded",
                                  finished_at: Time.current)

      get "/api/v1/admin/workflows/#{original.id}", headers: auth
      expect(response).to be_successful

      body = parse_body
      expect(body).to include("id" => original.id, "trigger_kind" => "initial")
      expect(body["steps"]).to be_an(Array)
      expect(body["steps"].size).to be > 0
      # Sibling workflow on the same Job is NOT here — that's the
      # whole point of this endpoint vs /api/v1/admin/jobs/:id.
      expect(body).not_to have_key("workflows")
      expect(body["job"]).to include(
        "id"           => job.id,
        "repository"   => job.repository.slug,
        "issue_number" => job.issue_number
      )
    end

    it "404s for an unknown workflow id" do
      get "/api/v1/admin/workflows/999999", headers: auth
      expect(response).to have_http_status(:not_found)
    end

    it "401s without a token" do
      get "/api/v1/admin/workflows/#{workflow.id}"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
