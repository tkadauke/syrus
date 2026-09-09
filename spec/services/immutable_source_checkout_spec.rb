require "rails_helper"
require "tmpdir"

RSpec.describe ImmutableSourceCheckout, :ci_only do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-immutable-source-bare")) }
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main", distributed_workflow_dag_enabled: true) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:creator_step) { Step.create!(workflow: workflow, kind: "grader_fanout", position: 0, state: "succeeded") }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 1,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => snapshot.id }
    )
  end
  let(:snapshot) do
    WorkflowSourceSnapshots.record!(
      workflow: workflow,
      creator_step: creator_step,
      source_sha: main_sha,
      source_ref: "refs/heads/main",
      tree_sha: main_tree_sha
    )
  end

  before do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    seed_remote(bare_remote_dir)
    @data_root = Dir.mktmpdir("syrus-immutable-source-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
    allow(GithubAuthenticatedGit).to receive(:run) do |repository:, user:, git:, operation_type:, log:, &block|
      block.call("file://#{bare_remote_dir}")
    end
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  it "materializes a detached checkout at the workflow source snapshot SHA" do
    checkout = described_class.new(step)

    checkout.setup

    expect(sh("git -C #{checkout.path} rev-parse HEAD").strip).to eq(main_sha)
    expect(sh("git -C #{checkout.path} rev-parse --abbrev-ref HEAD").strip).to eq("HEAD")
    expect(checkout.path.to_s).to include("/workflows/#{workflow.id}/.syrus/immutable-checkouts/steps/#{step.id}")
  end

  it "is cleaned up by the existing workflow workspace cleanup path" do
    checkout = described_class.new(step)
    checkout.setup
    step.update!(state: "succeeded")

    WorkflowWorkspace.cleanup_for(workflow)

    expect(WorkflowWorkspace.path_for(workflow)).not_to exist
    expect(workflow.reload.cleaned_up_at).to be_present
  end

  it "classifies a missing source ref as infrastructure state" do
    snapshot.update!(source_ref: "refs/heads/missing")

    expect { described_class.new(step).setup }
      .to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /missing ref refs\/heads\/missing/)
  end

  it "classifies a post-checkout SHA mismatch as infrastructure state" do
    git = instance_double(GitRunner)
    FileUtils.mkdir_p(described_class.path_for(step).join(".git"))
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: anything).and_return("#{main_sha}\n", "different-sha\n")

    checkout = described_class.new(step, git: git)

    expect { checkout.setup }
      .to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /SHA mismatch/)
  end

  it "refuses direct immutable checkout use when the distributed gate is off" do
    step
    Feature.find_by!(slug: "distributed_workflow_dag").update!(enabled: false)

    expect { described_class.new(step).setup }
      .to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /disabled/)
  end

  def main_sha
    @main_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main").strip
  end

  def main_tree_sha
    @main_tree_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main^{tree}").strip
  end

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-immutable-source-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(File.join(seed, "README.md"), "hello\n")
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'initial' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "s@e",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "s@e" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
