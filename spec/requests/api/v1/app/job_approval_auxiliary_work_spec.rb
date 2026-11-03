require "rails_helper"

RSpec.describe "Approving a job with a blocked auxiliary workflow", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repo, state: "implemented", auto_merge_enabled: true) }

  before { sign_in_as(user) }

  it "records the approval through the API despite a blocked visual_diff WorkUnit" do
    wf = Workflow.create!(job: job, trigger_kind: "visual_diff", state: "blocked")
    attach_work_unit(wf, kind: "visual_diff", state: "blocked", blocked_reason: "agent_cannot_proceed")

    post "/api/v1/app/jobs/#{job.id}/approve"

    expect(response).to have_http_status(:ok)
    expect(job.job_approvals.where(user: user)).to exist
  end

  it "still rejects approval through the API while an implement workflow is in flight" do
    wf = Workflow.create!(job: job, trigger_kind: "retry", state: "running")
    attach_work_unit(wf, kind: "retry", state: "running")

    post "/api/v1/app/jobs/#{job.id}/approve"

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.job_approvals).to be_empty
  end
end
