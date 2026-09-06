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
    allow(BranchPatchPresence).to receive(:classify)

    reason = described_class.reason(job: job, pr: OpenStruct.new(merged: true), client: client)

    expect(reason).to eq("pr_merged")
    expect(BranchPatchPresence).not_to have_received(:classify)
  end

  # JOB-4346: a merge train landed the work, member reconciliation failed to
  # close the Job, and the PR was eventually closed unmerged. Every commit had
  # an equivalent on main, which used to be filed as "this Job did nothing".
  it "returns pr_merged when every commit already has an equivalent on base" do
    allow(BranchPatchPresence).to receive(:classify).and_return(BranchPatchPresence::ALL_LANDED)

    expect(described_class.reason(job: job, pr: pr, client: client)).to eq("pr_merged")
  end

  it "returns no_changes only when the branch never held a commit" do
    allow(BranchPatchPresence).to receive(:classify).and_return(BranchPatchPresence::NO_COMMITS)

    expect(described_class.reason(job: job, pr: pr, client: client)).to eq("no_changes")
  end

  it "returns pr_closed when the branch still has unique patches" do
    allow(BranchPatchPresence).to receive(:classify).and_return(BranchPatchPresence::HAS_UNIQUE)

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

  describe ".classify" do
    it "reports ALL_LANDED when every commit has an equivalent on base" do
      allow(git).to receive(:run).and_return("", "", "- abc already applied\n- def already applied\n")

      expect(described_class.classify(job: job, pr: pr, client: client, git: git))
        .to eq(described_class::ALL_LANDED)
    end

    # The distinction the old boolean collapsed: nothing on the branch at all
    # is a genuine "no changes", and must not be confused with work that
    # landed.
    it "reports NO_COMMITS when the branch is not ahead of base at all" do
      allow(git).to receive(:run).and_return("", "", "")

      expect(described_class.classify(job: job, pr: pr, client: client, git: git))
        .to eq(described_class::NO_COMMITS)
    end

    it "reports HAS_UNIQUE when any commit is missing from base" do
      allow(git).to receive(:run).and_return("", "", "- abc already applied\n+ def still unique\n")

      expect(described_class.classify(job: job, pr: pr, client: client, git: git))
        .to eq(described_class::HAS_UNIQUE)
    end

    it "assumes unmerged work when the check cannot run" do
      allow(git).to receive(:run).and_raise(GitRunner::GitError.new(%w[cherry], 1, "boom"))

      expect(described_class.classify(job: job, pr: pr, client: client, git: git))
        .to eq(described_class::HAS_UNIQUE)
    end
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
