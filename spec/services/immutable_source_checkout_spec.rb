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
    Feature.find_or_initialize_by(slug: "distributed_workflow_dag").tap do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
      feature.enabled = true
      feature.save!
    end
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

  it "preserves the workflow base ref when the source snapshot is a synthetic ref" do
    snapshot.update!(
      source_ref: "refs/syrus/source-snapshots/runs/123",
      source_sha: feature_sha,
      tree_sha: feature_tree_sha
    )

    checkout = described_class.new(step)
    checkout.setup

    expect(sh("git -C #{checkout.path} rev-parse HEAD").strip).to eq(feature_sha)
    expect(sh("git -C #{checkout.path} rev-parse refs/remotes/origin/main").strip).to eq(main_sha)
    expect(sh("git -C #{checkout.path} diff --name-only origin/main...HEAD").lines.map(&:strip)).to eq([ "feature.txt" ])
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
    expect(step.reload.details.fetch("immutable_source_checkout")).to include(
      "worker_storage_key" => "storage-a",
      "source_snapshot_id" => snapshot.id,
      "source_snapshot_sha" => main_sha,
      "source_snapshot_ref" => "refs/heads/main",
      "prepare_cache_status" => "miss",
      "checkout_path" => described_class.path_for(step).to_s
    )
    expect(run.reload.head_sha).to eq(main_sha)
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

  it "rejects a local prepare cache restore whose npm dependency binaries are incomplete" do
    described_class.new(step).setup
    cache_path = Pathname.new(step.reload.details.fetch("prepare_cache").fetch("cache_path"))
    package_json = { "scripts" => { "typecheck" => "tsc --noEmit" }, "devDependencies" => { "typescript" => "1.0.0" } }
    package_lock = {
      "name" => "widgets",
      "lockfileVersion" => 3,
      "packages" => {
        "" => { "devDependencies" => { "typescript" => "1.0.0" } },
        "node_modules/typescript" => {
          "version" => "1.0.0",
          "bin" => { "tsc" => "bin/tsc" }
        }
      }
    }
    cache_path.join("package.json").write(JSON.generate(package_json))
    cache_path.join("package-lock.json").write(JSON.generate(package_lock))
    FileUtils.mkdir_p(cache_path.join("node_modules"))
    cache_path.join("node_modules/.package-lock.json").write(JSON.generate(package_lock))
    marker = JSON.parse(cache_path.join(described_class::PREPARED_MARKER).read)
    marker["dependency_state"] = {
      "manager" => "npm",
      "package_json_sha256" => Digest::SHA256.file(cache_path.join("package.json")).hexdigest,
      "package_lock_sha256" => Digest::SHA256.file(cache_path.join("package-lock.json")).hexdigest,
      "node_modules_package_lock_sha256" => Digest::SHA256.file(cache_path.join("node_modules/.package-lock.json")).hexdigest,
      "required_bins" => [ "tsc" ],
      "missing_bins" => []
    }
    cache_path.join(described_class::PREPARED_MARKER).write(JSON.pretty_generate(marker))
    repaired_plan = RepoPrepPlan::Result.new(
      commands: [
        "mkdir -p node_modules/.bin node_modules && " \
          "printf '{}' > node_modules/.package-lock.json && " \
          "printf '#!/bin/sh\\n' > node_modules/.bin/tsc && chmod +x node_modules/.bin/tsc"
      ],
      source: ".syrus.yml",
      note: nil
    )
    allow(RepoPrepPlan).to receive(:for).and_call_original
    allow(RepoPrepPlan).to receive(:for).with(described_class.path_for(second_step)).and_return(repaired_plan)
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    expect(second_step.reload.details.fetch("prepare_cache")).to include("status" => "miss")
    expect(second_checkout.path.join("node_modules/.bin/tsc")).to be_executable
    expect(ProcessRunner).to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "allows skipped prepare plans to cache JavaScript checkouts without installed dependencies" do
    source_path = Pathname.new(Dir.mktmpdir("syrus-unprepared-js-checkout"))
    source_path.join("package.json").write(JSON.generate("devDependencies" => { "typescript" => "1.0.0" }))
    source_path.join("package-lock.json").write(JSON.generate(
      "lockfileVersion" => 3,
      "packages" => {
        "" => { "devDependencies" => { "typescript" => "1.0.0" } },
        "node_modules/typescript" => { "bin" => { "tsc" => "bin/tsc" } }
      }
    ))
    empty_plan = RepoPrepPlan::Result.new(commands: [], source: ".syrus.yml", note: "prepare: [] — no commands")
    prepare_cache = described_class::PrepareCache.new(
      workflow: workflow,
      step: step,
      snapshot: snapshot,
      plan: empty_plan,
      worker_storage_key: "storage-a"
    )

    expect(prepare_cache.dependency_state_for(source_path)).to eq({})
    expect { prepare_cache.store_from!(source_path) }.not_to raise_error
    expect(prepare_cache.path.join("package.json")).to exist
  ensure
    FileUtils.rm_rf(source_path) if source_path
  end

  it "restores prepared state from the source snapshot archive on another worker storage root" do
    described_class.new(step).setup
    first_cache_details = step.reload.details.fetch("prepare_cache")
    expect(snapshot.reload.prepared_workspace_archive).to be_attached

    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    second_checkout = described_class.new(second_step)
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout.setup

    second_cache_details = second_step.reload.details.fetch("prepare_cache")
    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_cache_details).to include(
      "status" => "archive_hit",
      "worker_storage_key" => "storage-b",
      "workflow_id" => workflow.id,
      "source_snapshot_id" => snapshot.id,
      "source_snapshot_sha" => main_sha,
      "prepare_fingerprint" => first_cache_details.fetch("prepare_fingerprint")
    )
    expect(second_cache_details["cache_key"]).not_to eq(first_cache_details.fetch("cache_key"))
    expect(second_step.reload.details.fetch("immutable_source_checkout")).to include(
      "worker_storage_key" => "storage-b",
      "prepare_cache_status" => "archive_hit"
    )
    expect(ProcessRunner).not_to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "restores the source checkout from the prepared archive before fetching on a fresh worker" do
    described_class.new(step).setup
    expect(snapshot.reload.prepared_workspace_archive).to be_attached

    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    allow(GithubAuthenticatedGit).to receive(:run).and_raise("unexpected remote fetch")

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    expect(sh("git -C #{second_checkout.path} rev-parse HEAD").strip).to eq(main_sha)
    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_step.reload.details.fetch("prepare_cache")).to include(
      "status" => "archive_hit",
      "worker_storage_key" => "storage-b",
      "source_snapshot_sha" => main_sha
    )
  end

  it "skips prepared archive upload when the archive exceeds the size cap" do
    stub_const("PreparedWorkspaceArchive::MAX_BYTES", 1)
    stub_const("ImmutableSourceCheckout::PREPARED_ARCHIVE_MAX_BYTES", 1)

    described_class.new(step).setup

    expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    expect(step.reload.details.fetch("prepare_cache")).to include("status" => "miss")
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
    snapshot.prepared_workspace_archive.attach(
      io: StringIO.new("archive"),
      filename: "prepared.tar.gz",
      content_type: "application/gzip"
    )
    expect(snapshot.reload.prepared_workspace_archive).to be_attached

    workflow.cleanup_workspace!

    expect(WorkflowWorkspace.path_for(workflow)).not_to exist
    expect(workflow.reload.cleaned_up_at).to be_present
    expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
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

  def feature_sha
    @feature_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/syrus/source-snapshots/runs/123").strip
  end

  def feature_tree_sha
    @feature_tree_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/syrus/source-snapshots/runs/123^{tree}").strip
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
      sh("git -C #{seed} checkout -q -b feature")
      File.write(File.join(seed, "feature.txt"), "feature\n")
      sh("git -C #{seed} add feature.txt")
      sh("git -C #{seed} commit -q -m 'feature' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
      sh("git --git-dir=#{bare_path} update-ref refs/syrus/source-snapshots/runs/123 refs/heads/feature")
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
