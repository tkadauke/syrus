require "rails_helper"

RSpec.describe Workflows::BaseRefreshRetry do
  let(:job) { Factories.job_record(state: "running") }

  it "records success provenance and uses normal terminal workspace cleanup" do
    workflow = described_class.instantiate(job: job, artifacts: {
      "checkpoint_ref" => "refs/syrus/checkpoints/runs/10", "checkpoint_sha" => "checkpoint-sha",
      RebaseTarget::BASE_BRANCH_ARTIFACT => "main", RebaseTarget::BASE_SHA_ARTIFACT => "base-sha"
    })
    workflow.update!(state: "running")
    allow(WorkflowWorkspace).to receive(:cleanup_for)

    workflow.succeed!

    expect(WorkflowWorkspace).to have_received(:cleanup_for).with(workflow)
    expect(workflow.reload.artifact("base_refresh_outcome")).to include("status" => "succeeded")
  end

  it "starts validation without an initial implementation pass" do
    workflow = described_class.instantiate(job: job, artifacts: {
      "checkpoint_ref" => "refs/syrus/checkpoints/runs/10", "checkpoint_sha" => "checkpoint-sha",
      RebaseTarget::BASE_BRANCH_ARTIFACT => "main", RebaseTarget::BASE_SHA_ARTIFACT => "base-sha"
    })
    kinds = workflow.steps.order(:position).pluck(:kind)
    expect(kinds.first(4)).to eq(%w[base_refresh_rebase agent_rebase publish_source_snapshot prepare])
    expect(kinds).not_to include("implement")
    expect(kinds).to include("summarize", "test_plan", "pr_open")
  end
end
