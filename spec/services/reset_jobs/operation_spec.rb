require "rails_helper"

RSpec.describe ResetJobs::Operation do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user:) }
  let(:action) { instance_double(ChatPendingAction, id: 91) }
  let(:client) { instance_double(GithubClient, close_pull_request: true, delete_branch: true, delete_ref: true) }

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_return(true)
  end

  it "returns a failed Job to normal queued admission with a fresh initial Workflow" do
    job = Factories.job_record(user:, repository:, state: "failed")

    described_class.new(job:, user:, reason: "Start over", pending_action: action).call

    expect(job.reload).to be_queued
    expect(job.workflows.where(trigger_kind: "initial")).to exist
  end

  it "returns a Job with an unsatisfied dependency to blocked without starting work" do
    prerequisite = Factories.job_record(user:, repository:, state: "failed", issue_number: 42)
    job = Factories.job_record(user:, repository:, state: "failed", issue_number: 43)
    JobDependency.create!(job:, depends_on_job: prerequisite, source: "manual")

    described_class.new(job:, user:, reason: "Start over", pending_action: action).call

    expect(job.reload).to be_blocked_by_epic
    expect(job.workflows).to be_empty
  end
end
