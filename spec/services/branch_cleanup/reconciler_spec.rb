require "rails_helper"

RSpec.describe BranchCleanup::Reconciler do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:client) { instance_double(GithubClient, list_open_pull_requests: [], branch_head_sha: "owned-sha", delete_branch: true) }

  before { allow(GithubClient).to receive(:for).and_return(client) }

  def reconcile(branch: "syrus/job-bundle-1", sha: "owned-sha", **options)
    described_class.new(repository: repository, user: user, branch_name: branch, recorded_sha: sha, **options).call
  end

  it "deletes a proven Syrus-owned branch" do
    expect(reconcile.status).to eq(:deleted)
    expect(client).to have_received(:delete_branch).with(repository.slug, "syrus/job-bundle-1")
  end

  it "treats an already missing ref as reconciled" do
    allow(client).to receive(:branch_head_sha).and_return(nil)
    expect(reconcile.status).to eq(:deleted)
    expect(client).not_to have_received(:delete_branch)
  end

  it "protects a ref whose SHA moved" do
    allow(client).to receive(:branch_head_sha).and_return("different-sha")
    expect(reconcile.status).to eq(:protected)
    expect(client).not_to have_received(:delete_branch)
  end

  it "protects open pull request heads and bases" do
    pr = Struct.new(:head, :base).new(Struct.new(:ref).new("other"), Struct.new(:ref).new("syrus/job-bundle-1"))
    allow(client).to receive(:list_open_pull_requests).and_return([ pr ])
    expect(reconcile.status).to eq(:protected)
  end

  it "protects branches owned by active jobs, workflows, and merge trains" do
    active_job = Factories.job_record(user: user, repository: repository, branch_name: "syrus/live", state: "running")
    expect(reconcile(branch: active_job.branch_name).status).to eq(:protected)

    closed_job = Factories.job_record(user: user, repository: repository, branch_name: "syrus/workflow", state: "running")
    Workflow.create!(job: closed_job, trigger_kind: "initial", state: "running")
    closed_job.update_column(:state, "closed")
    expect(reconcile(branch: closed_job.branch_name).status).to eq(:protected)

    artifact_job = Factories.job_record(user: user, repository: repository, branch_name: "syrus/other", state: "running")
    artifact_workflow = Workflow.create!(job: artifact_job, trigger_kind: "initial", state: "running")
    artifact_workflow.set_artifact!(WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT, "syrus/required")
    expect(reconcile(branch: "syrus/required").status).to eq(:protected)

    MergeTrain.create!(repository: repository, priority: "medium", base_branch: repository.default_branch,
      integration_branch: "syrus/train", state: "grading")
    expect(reconcile(branch: "syrus/train").status).to eq(:protected)
  end

  it "protects a closed parent branch required by open stacked work" do
    parent = Factories.job_record(user: user, repository: repository, branch_name: "syrus/parent", state: "closed")
    Factories.job_record(user: user, repository: repository, branch_name: "syrus/child", state: "running", parent_job: parent)
    expect(reconcile(branch: parent.branch_name, owner_job: parent).status).to eq(:protected)
  end

  it "leaves API failures retryable" do
    allow(client).to receive(:list_open_pull_requests).and_raise(Octokit::ServerError.new)
    expect(reconcile.status).to eq(:failed)
    expect(client).not_to have_received(:delete_branch)
  end

  it "supports non-mutating dry runs" do
    expect(reconcile(dry_run: true).status).to eq(:candidate)
    expect(client).not_to have_received(:delete_branch)
  end
end
