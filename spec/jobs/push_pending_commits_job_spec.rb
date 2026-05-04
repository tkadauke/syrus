require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe PushPendingCommitsJob do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-push-bare")) }
  let(:user)       { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job)        { Factories.job(repository: repository, issue_number: 42) }
  let(:workflow) do
    Workflow.create!(job: job, trigger_kind: "initial",
                     state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
  end

  before do
    seed_remote(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    @data_root = Dir.mktmpdir("syrus-push-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  def workspace_path
    WorkflowWorkspace.path_for(workflow)
  end

  def setup_workspace_with_commit(branch: "syrus/issue-42-#{job.id}")
    path = workspace_path
    sh("git clone -q file://#{bare_remote_dir} #{path}")
    sh("git -C #{path} checkout -q -b #{branch}")
    File.write(path.join("feature.rb"), "def greet; 'hello'; end\n")
    sh("git -C #{path} add .")
    sh("git -C #{path} commit -q -m 'Add greeting'")
    branch
  end

  def setup_workspace_with_uncommitted_only(branch: "syrus/issue-42-#{job.id}")
    path = workspace_path
    sh("git clone -q file://#{bare_remote_dir} #{path}")
    sh("git -C #{path} checkout -q -b #{branch}")
    File.write(path.join("wip.rb"), "# work in progress\n")
    branch
  end

  it "pushes committed changes to the remote and stamps artifacts" do
    branch = setup_workspace_with_commit

    described_class.perform_now(workflow.id)

    remote_branches = `git --git-dir=#{bare_remote_dir} branch --list 'syrus/*'`.split("\n").map(&:strip)
    expect(remote_branches).to include(branch)

    workflow.reload
    expect(workflow.artifact("commits_pushed_at")).to be_present
    expect(workflow.artifact("commits_pushed_branch")).to eq(branch)
  end

  it "stages and commits uncommitted changes before pushing" do
    branch = setup_workspace_with_uncommitted_only

    described_class.perform_now(workflow.id)

    tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{branch}`.strip
    expect(tip).to eq("Unfinished work from Syrus agent (operator-pushed)")

    # File should be in the commit on the remote.
    content = `git --git-dir=#{bare_remote_dir} show #{branch}:wip.rb 2>&1`
    expect(content).to include("work in progress")
  end

  it "is a no-op when the workspace doesn't exist" do
    expect { described_class.perform_now(workflow.id) }.not_to raise_error
    expect(workflow.reload.artifact("commits_pushed_at")).to be_nil
  end

  it "is a no-op when commits_pushed_at artifact is already set" do
    workflow.set_artifact!("commits_pushed_at", 1.hour.ago.iso8601)
    # Workspace presence would cause git calls — ensure we skip them.
    expect(WorkflowWorkspace).not_to receive(:path_for)
    described_class.perform_now(workflow.id)
  end

  it "stamps commits_pushed_branch using the branch name from HEAD, not job.branch_name" do
    # branch_name on the job may be nil (first push); the job derives it from git.
    branch = setup_workspace_with_commit(branch: "syrus/issue-42-#{job.id}")
    expect(job.branch_name).to be_nil  # never set on this test job

    described_class.perform_now(workflow.id)

    expect(workflow.reload.artifact("commits_pushed_branch")).to eq("syrus/issue-42-#{job.id}")
  end

  # ---- helpers -------------------------------------------------------

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-push-seed") do |seed|
      sh("git init -q -b main #{seed}")
      sh("git -C #{seed} commit --allow-empty -q -m 'initial'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME"     => "Seed", "GIT_AUTHOR_EMAIL"    => "seed@example.com",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "seed@example.com" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
