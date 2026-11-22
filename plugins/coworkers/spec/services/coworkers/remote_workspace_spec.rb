require "rails_helper"

RSpec.describe Coworkers::RemoteWorkspace, :allow_host_execution do
  let(:user) { Factories.user }

  around do |example|
    Dir.mktmpdir("coworker-remote-spec-") do |root|
      @root = root
      @bare_remote = File.join(root, "coworker-homes.git")
      GitRunner.new.run("init", "--bare", @bare_remote)
      example.run
    end
  end

  def remote_workspace
    described_class.new(owner: "acme", name: "coworker-homes", user: user).tap do |remote|
      allow(remote).to receive(:authenticated_url).and_return(@bare_remote)
    end
  end

  def seed(remote, branch: "coworkers/maya")
    remote.seed!(
      branch: branch,
      files: { "SOUL.md" => "role: tester\n" },
      identity: Coworkers::GitIdentity.new(name: "Maya", handle: "maya")
    )
  end

  it "deletes a coworker branch when called outside a Git repository" do
    remote = remote_workspace
    seed(remote)
    caller_directory = File.join(@root, "not-a-repository")
    FileUtils.mkdir_p(caller_directory)

    Dir.chdir(caller_directory) { remote.delete!("coworkers/maya") }

    expect(remote.branch_exists?("coworkers/maya")).to be(false)
  end

  it "does not delete refs outside the coworker namespace" do
    remote = remote_workspace

    expect { remote.delete!("main") }
      .to raise_error(ArgumentError, "coworker pushes may only target refs under coworkers/")
  end


  it "does not delete a ref that moves after its expected SHA was recorded" do
    remote = remote_workspace
    expected_sha = seed(remote)

    Dir.mktmpdir("coworker-ref-race-") do |checkout|
      GitRunner.new.run("clone", "--branch", "coworkers/maya", "--single-branch", @bare_remote, checkout)
      File.write(File.join(checkout, "SOUL.md"), "role: changed\n")
      git = GitRunner.new
      git.configure_author(Coworkers::GitIdentity.new(name: "Maya", handle: "maya"), chdir: checkout)
      git.run("add", "SOUL.md", chdir: checkout)
      git.run("commit", "-m", "Claim branch", chdir: checkout)
      git.run("push", @bare_remote, "HEAD:refs/heads/coworkers/maya", chdir: checkout)
    end
    changed_sha = remote.branch_sha("coworkers/maya")

    expect {
      remote.delete_if_matches!("coworkers/maya", expected_sha: expected_sha)
    }.to raise_error(Coworkers::RemoteWorkspace::RefChanged)
    expect(remote.branch_sha("coworkers/maya")).to eq(changed_sha)
  end

  it "deletes a ref atomically when its SHA still matches" do
    remote = remote_workspace
    expected_sha = seed(remote)

    remote.delete_if_matches!("coworkers/maya", expected_sha: expected_sha)

    expect(remote.branch_sha("coworkers/maya")).to be_nil
  end

  it "filters merged run refs in one git process instead of checking each ref separately" do
    git = instance_double(GitRunner)
    coworker = instance_double(Coworkers::Coworker, id: 12, handle: "maya")
    remote = described_class.new(owner: "acme", name: "coworker-homes", user:, git:,
      authenticated_url: @bare_remote)
    allow(git).to receive(:capture)
    allow(git).to receive(:run).with("init", anything)
    allow(git).to receive(:run).with("fetch", "--no-tags", @bare_remote,
      "+refs/heads/coworkers/maya:refs/remotes/workspace/home",
      "+refs/heads/coworkers/run/12-*:refs/remotes/workspace/runs/*", chdir: anything)
    allow(git).to receive(:run).with("for-each-ref", "--merged=refs/remotes/workspace/home",
      "--format=%(refname) %(objectname) %(committerdate:unix)",
      "refs/remotes/workspace/runs", chdir: anything)
      .and_return("refs/remotes/workspace/runs/345 #{'a' * 40} 1700000000\n")

    refs = remote.merged_run_refs(home_branch: "coworkers/maya", run_prefix: "coworkers/run/12-",
      guard: Coworkers::PushGuard.new(coworker:))

    expect(refs).to contain_exactly(branch: "coworkers/run/12-345", sha: "a" * 40,
      committed_at: Time.zone.at(1_700_000_000))
    expect(git).not_to have_received(:capture)
  end
end
