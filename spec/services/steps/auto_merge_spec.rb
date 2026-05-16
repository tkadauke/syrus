require "rails_helper"
require "ostruct"

RSpec.describe Steps::AutoMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:workflow) { Workflows::AutoMerge.instantiate(job: job) }
  let(:step) { workflow.steps.last }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "auto_merge") }
  let(:client) { instance_double(GithubClient) }

  def pr(state: "open")
    OpenStruct.new(
      state: state,
      mergeable_state: "clean",
      labels: [],
      head: OpenStruct.new(sha: "abc")
    )
  end

  before do
    workflow.start!
    workflow.save!
    step.start!
    step.save!
    run.start!
    run.save!

    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])
    allow(client).to receive(:pr_issue_comments).and_return([])
    allow(client).to receive(:pr_commits).and_return([])
  end

  it "re-verifies gates, merges via GitHub, comments, and closes the Job" do
    job.approve!
    job.start_landing!
    job.save!
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
    allow(client).to receive(:add_issue_comment)

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
      .with("acme/widgets", 7, hash_including(merge_method: "rebase"))
    expect(client).to have_received(:add_issue_comment).with("acme/widgets", 7, include("Job ##{job.id}"))
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("pr_merged")
  end

  it "cancels the run and workflow when the PR was already closed" do
    allow(client).to receive(:pull_request).and_return(pr(state: "closed"))

    described_class.new(run).call

    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
  end

  it "queues the merge attempt while a stack parent is still open" do
    parent = Factories.job(user: user, repository: repository, issue_number: 41, pr_number: 6)
    job.update!(parent_job: parent)
    allow(client).to receive(:merge_pull_request)

    described_class.new(run).call

    expect(client).not_to have_received(:merge_pull_request)
    expect(workflow.reload.artifact("pending_auto_merge")).to eq("waiting_for_parent")
    expect(run.reload).to be_cancelled
    expect(run.job_logs.last.chunk).to include("waiting for parent #6 to merge")
  end
end
