require "rails_helper"

RSpec.describe "App API workflow warnings", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:warning) do
    WorkflowWarnings.record!(
      workflow: workflow,
      kind: "grader_side_effect",
      title: "Grader left changes",
      evidence: { "grader_name" => "tests", "changed_files" => [ "foo.txt" ] },
      suggested_prompt: "Fix the grader"
    )
  end

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def file_job_path(warning_record) = "/api/v1/app/jobs/#{job.id}/workflow_warnings/#{warning_record.id}/file_job"
  def dismiss_path(warning_record) = "/api/v1/app/jobs/#{job.id}/workflow_warnings/#{warning_record.id}/dismiss"

  describe "POST .../file_job" do
    it "creates a direct Job from the prompt and stamps created_job_id" do
      path = file_job_path(warning)

      expect {
        post path, params: { prompt: "Fix the grader please" }, as: :json
      }.to change(Job, :count).by(1)

      expect(response).to have_http_status(:created)
      body = parse_body
      expect(body["message"]).to include(body.dig("job", "slug"))
      expect(body["job"]).to include("state", "job_path")
      expect(body["warning"]["created_job_id"]).to eq(body.dig("job", "id"))

      created_job = Job.find(body.dig("job", "id"))
      expect(created_job.kind).to eq("direct")
      expect(created_job.issue_body).to eq("Fix the grader please")
      expect(created_job.repository).to eq(repo)
    end

    it "rejects a blank prompt" do
      path = file_job_path(warning)

      expect {
        post path, params: { prompt: "   " }, as: :json
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(warning.reload.created_job_id).to be_nil
    end

    it "404s for a warning that doesn't belong to the requested job" do
      other_job = Factories.job_record(repository: repo, issue_number: 43)

      post "/api/v1/app/jobs/#{other_job.id}/workflow_warnings/#{warning.id}/file_job", params: { prompt: "fix it" }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the job doesn't belong to the current user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
      other_job = Factories.job_record(repository: other_repo, issue_number: 99)
      other_workflow = Workflow.create!(job: other_job, trigger_kind: "initial")
      other_warning = WorkflowWarnings.record!(workflow: other_workflow, kind: "grader_side_effect", title: "x", suggested_prompt: "y")

      post file_job_path(other_warning), params: { prompt: "fix it" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST .../dismiss" do
    it "dismisses a pending warning" do
      post dismiss_path(warning), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("warning", "state")).to eq("dismissed")
      expect(warning.reload.state).to eq("dismissed")
    end

    it "rejects dismissing an already-dismissed warning" do
      warning.dismiss!

      post dismiss_path(warning), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
