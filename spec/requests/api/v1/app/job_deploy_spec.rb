require "rails_helper"

RSpec.describe "App API job deploy", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42, state: "implemented") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def deploy_path(job_record) = "/api/v1/app/jobs/#{job_record.id}/deploy"

  describe "GET /api/v1/app/jobs/:job_id/deploy" do
    it "returns null deploy when none exists" do
      get deploy_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("deploy" => nil)
    end

    it "returns the most recent deploy workflow" do
      workflow = Workflows::Deploy.instantiate(job: job)
      workflow.update_columns(state: "running", started_at: Time.current)

      get deploy_path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["deploy"]).to include("id" => workflow.id, "state" => "running")
    end

    it "does not expose another user's job" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo)

      get deploy_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/deploy" do
    before { allow(App::DeployAvailability).to receive(:allow_unapproved?).and_return(false) }

    it "rejects jobs that are not implemented, approved, or landing" do
      job.update_columns(state: "queued")

      expect {
        post deploy_path(job), as: :json
      }.not_to change { job.workflows.where(trigger_kind: "deploy").count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "rejects an unapproved job by default" do
      job.update_columns(state: "implemented")

      expect {
        post deploy_path(job), as: :json
      }.not_to change { job.workflows.where(trigger_kind: "deploy").count }

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("forbidden")
      expect(parse_body.dig("error", "message")).to include("Approve the Job first")
    end

    it "allows an unapproved job when the repository opts in via deploy.allow_unapproved" do
      allow(App::DeployAvailability).to receive(:allow_unapproved?).and_return(true)
      job.update_columns(state: "implemented")

      expect {
        post deploy_path(job), as: :json
      }.to change { job.workflows.where(trigger_kind: "deploy").count }.by(1)
        .and have_enqueued_job(RunJob)

      expect(response).to have_http_status(:created)
      expect(parse_body["deploy"]).to include("state" => "queued")
      expect(parse_body["message"]).to eq("Deploy workflow enqueued.")
    end

    it "allows an approved job regardless of the allow_unapproved config" do
      job.update_columns(state: "approved")

      expect {
        post deploy_path(job), as: :json
      }.to change { job.workflows.where(trigger_kind: "deploy").count }.by(1)
        .and have_enqueued_job(RunJob)

      expect(response).to have_http_status(:created)
    end

    it "allows a closed job that landed with a merged commit sha" do
      allow(App::DeployAvailability).to receive(:allow_unapproved?).and_return(true)
      job.update_columns(state: "closed", landed_sha: "abc123")

      expect {
        post deploy_path(job), as: :json
      }.to change { job.workflows.where(trigger_kind: "deploy").count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "rejects creation when a deploy is already queued or running" do
      job.update_columns(state: "approved")
      Workflows::Deploy.instantiate(job: job)

      expect {
        post deploy_path(job), as: :json
      }.not_to change { job.workflows.where(trigger_kind: "deploy").count }

      expect(response).to have_http_status(:conflict)
      expect(parse_body.dig("error", "code")).to eq("conflict")
    end

    it "allows creation again once the previous deploy has finished" do
      job.update_columns(state: "approved")
      previous = Workflows::Deploy.instantiate(job: job)
      previous.update_columns(state: "succeeded", finished_at: Time.current)

      expect {
        post deploy_path(job), as: :json
      }.to change { job.workflows.where(trigger_kind: "deploy").count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "does not expose another user's job" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job_record(repository: other_repo, state: "approved")

      post deploy_path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
