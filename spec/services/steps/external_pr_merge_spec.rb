require "rails_helper"
require "ostruct"

RSpec.describe Steps::ExternalPrMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  # external_pr Jobs must be created in :implemented state (validated on create).
  # Factories.job_record always overrides state to "closed" then update_columns,
  # so we use Job.create! directly for external_pr kind.
  let(:job) do
    Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "external_pr",
      issue_number: nil,
      external_pr_number: 99,
      state: "implemented"
    )
  end
  let(:workflow) { Workflows::ExternalPrMerge.instantiate(job: job) }
  let(:step) { workflow.steps.last }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "external_pr_merge") }
  let(:client) { instance_double(GithubClient) }

  def pr(state: "open", mergeable_state: "clean", merged: false)
    OpenStruct.new(
      state: state,
      mergeable_state: mergeable_state,
      merged: merged,
      labels: [],
      head: OpenStruct.new(sha: "abc123"),
      base: OpenStruct.new(ref: "main", sha: "base")
    )
  end

  before do
    job.approve!(via: "operator")
    job.start_landing!
    job.save!
    workflow.start!
    workflow.save!
    step.start!
    step.save!
    run.start!
    run.save!

    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
  end

  it "merges the external PR via GitHub and closes the job" do
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
      .with("acme/widgets", 99, hash_including(merge_method: "rebase"))
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("external_pr_merged")
  end

  it "includes the repository slug and PR number in the commit title" do
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
      .with(anything, anything, hash_including(commit_title: include("acme/widgets#99")))
  end

  it "pushes same-repository repair commits to the external PR head before merging" do
    workflow.set_artifact!("external_pr_head_repo", "acme/widgets")
    workflow.set_artifact!("external_pr_head_ref", "contributor-branch")
    workflow.set_artifact!("external_pr_head_sha", "abc123")
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
    allow(client).to receive(:access_token).and_return("ghs_test")
    allow(repository).to receive(:authenticated_push_url).and_return("https://token@example.com/acme/widgets.git")

    workspace = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/external-pr-workspace"))
    rev_git = instance_double(GitRunner)
    push_git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(rev_git, push_git)
    allow(rev_git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/external-pr-workspace").and_return("def456\n")
    allow(push_git).to receive(:run)
    allow_any_instance_of(described_class).to receive(:workspace).and_return(workspace)

    described_class.new(run).call

    expect(push_git).to have_received(:run)
      .with("push", "https://token@example.com/acme/widgets.git", "HEAD:refs/heads/contributor-branch", chdir: "/tmp/external-pr-workspace")
    expect(client).to have_received(:merge_pull_request)
  end

  it "raises StepFailed when GitHub does not confirm the merge" do
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: false))

    expect {
      described_class.new(run).call
    }.to raise_error(Steps::Base::StepFailed, /did not report PR #99 as merged/)
  end

  it "cancels the workflow and closes the job as merged when the PR is already merged" do
    allow(client).to receive(:pull_request).and_return(pr(state: "closed", merged: true))

    described_class.new(run).call

    expect(workflow.reload).to be_cancelled
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("external_pr_merged")
  end

  it "cancels the workflow and closes the job as closed when the PR was closed without merging" do
    allow(client).to receive(:pull_request).and_return(pr(state: "closed", merged: false))

    described_class.new(run).call

    expect(workflow.reload).to be_cancelled
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("external_pr_closed")
  end

  it "defers landing and cancels the workflow on transient GitHub errors" do
    allow(client).to receive(:merge_pull_request)
      .and_raise(Octokit::ServiceUnavailable.new(status: 503, body: "unavailable"))

    described_class.new(run).call

    expect(job.reload).to be_approved
    expect(workflow.reload).to be_cancelled
  end

  it "raises StepFailed on a non-retryable GitHub API error" do
    allow(client).to receive(:merge_pull_request)
      .and_raise(Octokit::UnprocessableEntity.new(status: 422, body: { message: "Merge conflict" }))

    expect {
      described_class.new(run).call
    }.to raise_error(Steps::Base::StepFailed, /GitHub merge failed/)
  end

  it "raises StepFailed on MethodNotAllowed (e.g. repo doesn't support rebase merges)" do
    allow(client).to receive(:merge_pull_request)
      .and_raise(Octokit::MethodNotAllowed.new(status: 405, body: { message: "Rebase merging not allowed" }))

    expect {
      described_class.new(run).call
    }.to raise_error(Steps::Base::StepFailed, /GitHub merge failed/)
  end
end
