require "rails_helper"
require "ostruct"
require "tmpdir"

RSpec.describe ClosedPullRequestResolution do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:client) { instance_double(GithubClient, access_token: "ghp_test") }
  let(:pr) { OpenStruct.new(merged: false, base: OpenStruct.new(ref: "main")) }

  it "returns pr_merged for merged pull requests" do
    allow(BranchPatchPresence).to receive(:no_unique_commits?)

    reason = described_class.reason(job: job, pr: OpenStruct.new(merged: true), client: client)

    expect(reason).to eq("pr_merged")
    expect(BranchPatchPresence).not_to have_received(:no_unique_commits?)
  end

  it "returns no_changes when the branch has no unique patches against base" do
    allow(BranchPatchPresence).to receive(:no_unique_commits?).and_return(true)

    expect(described_class.reason(job: job, pr: pr, client: client)).to eq("no_changes")
  end

  it "returns pr_closed when the branch still has unique patches" do
    allow(BranchPatchPresence).to receive(:no_unique_commits?).and_return(false)

    expect(described_class.reason(job: job, pr: pr, client: client)).to eq("pr_closed")
  end
end

RSpec.describe BranchPatchPresence do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:client) { instance_double(GithubClient, access_token: "ghp_test") }
  let(:pr) { OpenStruct.new(base: OpenStruct.new(ref: "main")) }
  let(:git) { instance_double(GitRunner) }

  around do |example|
    original = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir("syrus-branch-patch-presence") do |dir|
      ENV["SYRUS_DATA_ROOT"] = dir
      example.run
    end
  ensure
    ENV["SYRUS_DATA_ROOT"] = original
  end

  it "returns true when git cherry reports only patch-equivalent commits" do
    allow(git).to receive(:run).and_return("", "", "- abc already applied\n")

    expect(described_class.no_unique_commits?(job: job, pr: pr, client: client, git: git)).to be(true)
  end

  it "returns false when git cherry reports a unique commit" do
    allow(git).to receive(:run).and_return("", "", "+ abc still unique\n")

    expect(described_class.no_unique_commits?(job: job, pr: pr, client: client, git: git)).to be(false)
  end

  it "returns false without cloning when the job has no branch name" do
    allow(git).to receive(:run)
    job.update_columns(branch_name: nil)

    expect(described_class.no_unique_commits?(job: job, pr: pr, client: client, git: git)).to be(false)
    expect(git).not_to have_received(:run)
  end

  it "returns false when the git check fails" do
    allow(git).to receive(:run).and_raise(GitRunner::GitError.new(%w[cherry], 1, "boom"))

    expect(described_class.no_unique_commits?(job: job, pr: pr, client: client, git: git)).to be(false)
  end

  it "removes the temporary clone when a later git command fails" do
    job_id = job.id
    allow(SecureRandom).to receive(:hex).with(8).and_return("fixed")
    clone_path = WorkflowWorkspace.data_root.join("closed-pr-checks", "#{job_id}-fixed")

    allow(git).to receive(:run) do |*args|
      if args.first == "clone"
        FileUtils.mkdir_p(clone_path)
        ""
      else
        raise GitRunner::GitError.new(args, 1, "fetch failed")
      end
    end

    expect(described_class.no_unique_commits?(job: job, pr: pr, client: client, git: git)).to be(false)
    expect(clone_path).not_to exist
  end
end
