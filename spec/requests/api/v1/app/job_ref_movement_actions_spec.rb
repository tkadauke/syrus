require "rails_helper"

RSpec.describe "App API job ref-movement actions", type: :request do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:fork_repo) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:job) { Factories.job_record(user: user, repository: fork_repo, issue_number: 7, state: "approved", branch_name: "syrus/issue-7") }

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  def app_job_path(path) = "/api/v1/app/jobs/#{job.id}#{path}"

  def stub_send_job_upstream_available!(branch: "main")
    config = SyrusYml::DeliveryRefMovementAction.new(name: "send_job_upstream", enabled: true, source: nil, target: nil, mode: "manual_pr", grade_phases: [])
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_enabled?).and_return(true)
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_target_branch).and_return(branch)
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_action_config).with("send_job_upstream").and_return(config)
  end

  it "dispatches send_job_upstream for an eligible job and returns 200" do
    sign_in_as(user)
    stub_send_job_upstream_available!

    expect {
      post app_job_path("/ref_movement_actions"), params: { action_name: "send_job_upstream" }, as: :json
    }.to change(RefMovementAction, :count).by(1)

    expect(response).to have_http_status(:ok)
    record = RefMovementAction.last
    expect(record).to be_dispatched
    expect(record.job).to eq(job)
    expect(record.workflow.trigger_kind).to eq("upstream_export")
  end

  it "returns 422 with the blocked reason when the job is not eligible" do
    sign_in_as(user)
    stub_send_job_upstream_available!
    job.update_columns(state: "closed", closure_reason: "pr_merged")

    expect {
      post app_job_path("/ref_movement_actions"), params: { action_name: "send_job_upstream" }, as: :json
    }.to change(RefMovementAction, :count).by(1)

    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body.dig("error", "message")).to include("not open")
    expect(RefMovementAction.last).to be_blocked
  end

  it "rejects ref-movement actions that are not job-scoped" do
    sign_in_as(user)

    post app_job_path("/ref_movement_actions"), params: { action_name: "submit_branch_upstream" }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires sign-in" do
    post app_job_path("/ref_movement_actions"), params: { action_name: "send_job_upstream" }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
