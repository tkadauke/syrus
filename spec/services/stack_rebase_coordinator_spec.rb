require "rails_helper"

RSpec.describe StackRebaseCoordinator do
  include ActiveJob::TestHelper

  let(:repository) { Factories.repository }
  let(:parent) do
    Factories.job(repository: repository, issue_number: 41).tap do |job|
      job.update!(branch_name: "syrus/issue-41-#{job.id}", pr_number: 41)
      job.runs.create!(trigger_kind: "initial", agent_provider: job.agent_provider, head_sha: "a" * 40)
    end
  end
  let(:child) do
    Factories.job(repository: repository, issue_number: 42).tap do |job|
      job.update!(parent_job: parent, branch_name: "syrus/issue-42-#{job.id}", pr_number: 42)
      job.workflows.update_all(state: "succeeded")
    end
  end

  before do
    child
    clear_enqueued_jobs
  end

  it "enqueues a rebase workflow for immediate children when the parent is amended" do
    expect {
      described_class.parent_amended(parent)
    }.to change { child.reload.workflows.where(trigger_kind: "rebase").count }.by(1)
      .and change { enqueued_jobs.count { |job| job[:job] == RunJob } }.by(1)
  end

  it "re-points children to main and rebases them when the parent merges" do
    expect {
      described_class.parent_merged(parent)
    }.to change { child.reload.parent_job_id }.from(parent.id).to(nil)
      .and change { child.workflows.where(trigger_kind: "rebase").count }.by(1)
      .and change { enqueued_jobs.count { |job| job[:job] == RunJob } }.by(1)
  end

  it "does not unwind children when the parent closes without merging" do
    parent.close_with_reason!("pr_closed")

    expect(child.reload.parent_job).to eq(parent)
    expect(child.workflows.where(trigger_kind: "rebase")).to be_empty
  end
end
