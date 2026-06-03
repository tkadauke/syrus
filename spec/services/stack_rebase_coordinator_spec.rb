require "rails_helper"
require "ostruct"

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
      JobDependency.create!(job: job, depends_on_job: parent, source: "manual")
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

  it "rebases amended children leaf-most first" do
    older_child = child
    newer_child = Factories.job(repository: repository, issue_number: 43).tap do |job|
      JobDependency.create!(job: job, depends_on_job: parent, source: "manual")
      job.update!(parent_job: parent, branch_name: "syrus/issue-43-#{job.id}", pr_number: 43)
      job.workflows.update_all(state: "succeeded")
    end
    dispatched = []
    allow(StepDispatcher).to receive(:start_workflow) { |workflow| dispatched << workflow }

    described_class.parent_amended(parent)

    expect(dispatched.map(&:job_id)).to eq([ newer_child.id, older_child.id ])
    expect(dispatched.map { |workflow| workflow.artifact("rebase_base_branch") }).to eq([
      parent.branch_name,
      parent.branch_name
    ])
  end

  it "re-points children to main and rebases them when the parent merges" do
    parent.update_columns(state: "closed", closure_reason: "pr_merged")
    client = instance_double(
      GithubClient,
      update_pull_request_base: nil,
      pull_request: OpenStruct.new(body: ""),
      update_pull_request_body: nil
    )
    allow(GithubClient).to receive(:for).and_return(client)

    expect {
      described_class.parent_merged(parent)
    }.to change { child.reload.parent_job_id }.from(parent.id).to(nil)
      .and change { child.workflows.where(trigger_kind: "rebase").count }.by(1)
      .and change { enqueued_jobs.count { |job| job[:job] == RunJob } }.by(1)

    expect(client).to have_received(:update_pull_request_base)
      .with(repository.slug, child.pr_number, base: repository.default_branch)
  end

  it "does not unwind children when the parent closes without merging" do
    parent.close_with_reason!("pr_closed")

    expect(child.reload.parent_job).to eq(parent)
    expect(child.workflows.where(trigger_kind: "rebase")).to be_empty
  end
end
