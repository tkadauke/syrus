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
  let(:second_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 2,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => snapshot.id }
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running") }
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
    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-a\n")
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
    expect(sh("git -C #{checkout.path} rev-parse refs/remotes/origin/main").strip).to eq(main_sha)
    expect(checkout.path.to_s).to include("/workflows/#{workflow.id}/.syrus/immutable-checkouts/steps/#{step.id}")
  end

  it "runs normal prepare commands in the immutable checkout dependency environment" do
    checkout = described_class.new(step)

    checkout.setup

    prepared_file = checkout.path.join(".syrus/deps/bundle/prepared.txt")
    expect(prepared_file).to exist
    expect(prepared_file.read).to eq("ready\n")
  end

  it "records prepare cache misses and command spans for the first immutable checkout on a worker" do
    Thread.current[:syrus_current_run] = run

    described_class.new(step).setup

    cache_details = step.reload.details.fetch("prepare_cache")
    expect(cache_details).to include(
      "status" => "miss",
      "worker_storage_key" => "storage-a",
      "workflow_id" => workflow.id,
      "source_snapshot_id" => snapshot.id,
      "source_snapshot_sha" => main_sha,
      "prepare_source" => ".syrus.yml",
      "command_count" => 1
    )
    expect(cache_details["prepare_fingerprint"]).to be_present
    expect(cache_details["cache_key"]).to eq(
      [
        "storage-a",
        workflow.id,
        main_sha,
        cache_details.fetch("prepare_fingerprint")
      ].join(":")
    )
    expect(run.reload.command_spans.ordered.map(&:command_excerpt)).to eq([
      "mkdir -p \"$BUNDLE_PATH\"",
      "printf 'ready\\n' > \"$BUNDLE_PATH/prepared.txt\""
    ])
    expect(run.command_spans.map(&:outcome)).to all(eq("succeeded"))
  ensure
    Thread.current[:syrus_current_run] = nil
  end

  it "reuses prepared state for later immutable-source steps with the same worker, workflow, snapshot, and fingerprint" do
    described_class.new(step).setup
    first_cache_details = step.reload.details.fetch("prepare_cache")

    second_checkout = described_class.new(second_step)
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout.setup

    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_step.reload.details.fetch("prepare_cache")).to include(
      "status" => "hit",
      "worker_storage_key" => "storage-a",
      "source_snapshot_sha" => main_sha,
      "prepare_fingerprint" => first_cache_details.fetch("prepare_fingerprint"),
      "cache_key" => first_cache_details.fetch("cache_key")
    )
    expect(ProcessRunner).not_to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "misses naturally when the prepare fingerprint changes" do
    described_class.new(step).setup
    first_cache_key = step.reload.details.dig("prepare_cache", "cache_key")
    changed_plan = instance_double(
      RepoPrepPlan::Result,
      source: ".syrus.yml",
      note: nil,
      guessed?: false,
      commands: [ "printf changed > prepared-by-new-fingerprint.txt" ]
    )
    allow(RepoPrepPlan).to receive(:for).and_call_original
    allow(RepoPrepPlan).to receive(:for).with(described_class.path_for(second_step)).and_return(changed_plan)

    described_class.new(second_step).setup

    second_cache_details = second_step.reload.details.fetch("prepare_cache")
    expect(second_cache_details["status"]).to eq("miss")
    expect(second_cache_details["cache_key"]).not_to eq(first_cache_key)
    expect(described_class.path_for(second_step).join("prepared-by-new-fingerprint.txt")).to exist
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

  it "classifies fetch failures as infrastructure state" do
    git = instance_double(GitRunner)
    allow(git).to receive(:run).with("init", anything).and_return("")
    allow(git).to receive(:run).with("remote", "add", "origin", anything, chdir: anything).and_return("")
    allow(git).to receive(:run).with(
      "fetch", "--no-tags", anything, "+refs/heads/main:refs/remotes/origin/main",
      chdir: anything,
      env: { "GIT_TERMINAL_PROMPT" => "0" }
    ).and_raise(GitRunner::GitError.new([ "fetch" ], 128, "network unavailable"))

    expect { described_class.new(step, git: git).setup }
      .to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /network unavailable/)
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
      File.write(File.join(seed, ".syrus.yml"), <<~YAML)
        prepare:
          - mkdir -p "$BUNDLE_PATH" && printf 'ready\\n' > "$BUNDLE_PATH/prepared.txt"
      YAML
      sh("git -C #{seed} add README.md .syrus.yml")
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
