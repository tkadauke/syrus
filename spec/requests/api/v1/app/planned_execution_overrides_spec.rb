require "rails_helper"

RSpec.describe "Job planned execution overrides", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "backlog", planned_execution_capabilities: ExecutionPlacementProfile.fetch("ios_xcode").capabilities, planned_execution_source: "classifier") }

  before { sign_in_as(user) }

  it "uses the shared audited operation from the Job UI endpoint" do
    post "/api/v1/app/jobs/#{job.id}/override_planned_execution", params: {
      profile: "linux", reason: "The requested work is platform-neutral.", entity_revision: job.entity_revision
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.planned_execution_capabilities).to eq("os" => [ "linux" ])
    expect(job.planned_execution_overrides.sole).to have_attributes(
      user: user, provenance: "job_ui", reason: "The requested work is platform-neutral."
    )
  end

  it "returns the precise safety refusal" do
    job.update!(state: "running")

    post "/api/v1/app/jobs/#{job.id}/override_planned_execution", params: {
      profile: "linux", reason: "Wrong host.", entity_revision: job.entity_revision
    }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).to_s).to include("once #{job.slug} is running")
    expect(job.planned_execution_overrides).to be_empty
  end
end
