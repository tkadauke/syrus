require "rails_helper"
require "tmpdir"

RSpec.describe ImmutableSourceCheckout, "npm prepare artifact validation" do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-immutable-source-bare")) }
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main", distributed_workflow_dag_enabled: true) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:creator_step) { Step.create!(workflow: workflow, kind: "grader_fanout", position: 0, state: "succeeded") }
  let(:step) { immutable_step(position: 1) }
  let(:second_step) { immutable_step(position: 2) }
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

  it "rejects a prepared cache hit when declared npm binaries are missing" do
    described_class.new(step).setup
    snapshot.reload.prepared_workspace_archive.purge
    cache_path = Pathname.new(step.reload.details.fetch("prepare_cache").fetch("cache_path"))
    write_incomplete_node_install(cache_path)

    second_checkout = described_class.new(second_step)
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout.setup

    expect(second_step.reload.details.fetch("prepare_cache")).to include(
      "status" => "miss",
      "worker_storage_key" => "storage-a",
      "source_snapshot_sha" => main_sha
    )
    expect(second_checkout.path.join("package-lock.json")).not_to exist
    expect(ProcessRunner).to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "rejects a prepared archive restore when declared npm binaries are missing" do
    first_checkout = described_class.new(step)
    first_checkout.setup
    first_cache_details = step.reload.details.fetch("prepare_cache")
    metadata = snapshot.reload.prepared_workspace_archive.blob.metadata
    write_incomplete_node_install(first_checkout.path)
    replace_prepared_archive_from!(first_checkout.path, metadata: metadata)

    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    second_checkout = described_class.new(second_step)
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout.setup

    expect(second_step.reload.details.fetch("prepare_cache")).to include(
      "status" => "miss",
      "worker_storage_key" => "storage-b",
      "source_snapshot_sha" => main_sha,
      "prepare_fingerprint" => first_cache_details.fetch("prepare_fingerprint")
    )
    expect(second_checkout.path.join("package-lock.json")).not_to exist
    expect(ProcessRunner).to have_received(:new).with(hash_including(kind: "prepare"))
  end

  def immutable_step(position:)
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: position,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => snapshot.id }
    )
  end

  def main_sha
    @main_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main").strip
  end

  def main_tree_sha
    @main_tree_sha ||= sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main^{tree}").strip
  end

  def write_incomplete_node_install(path)
    path = Pathname.new(path)
    File.write(path.join("package.json"), JSON.generate("scripts" => { "typecheck" => "tsc --noEmit" }))
    lock_json = JSON.pretty_generate(
      "lockfileVersion" => 3,
      "packages" => {
        "" => { "devDependencies" => { "typescript" => "5.9.2", "vitest" => "4.0.0" } },
        "node_modules/typescript" => { "bin" => { "tsc" => "bin/tsc", "tsserver" => "bin/tsserver" } },
        "node_modules/vitest" => { "bin" => { "vitest" => "vitest.mjs" } }
      }
    )
    File.write(path.join("package-lock.json"), lock_json)
    FileUtils.mkdir_p(path.join("node_modules/.bin"))
    File.write(path.join("node_modules/.package-lock.json"), lock_json)
    FileUtils.touch(path.join("node_modules/.bin/vitest"))
    FileUtils.rm_f(path.join("node_modules/.bin/tsc"))
    FileUtils.rm_f(path.join("node_modules/.bin/tsserver"))
  end

  def replace_prepared_archive_from!(source_path, metadata:)
    Dir.mktmpdir("syrus-corrupt-prepared-archive") do |dir|
      archive_path = Pathname.new(dir).join("prepared.tar.gz")
      _stdout, stderr, status = Open3.capture3(
        "tar", "--exclude=./.syrus/immutable-checkouts", "-czf", archive_path.to_s, "-C", source_path.to_s, "."
      )
      raise "tar failed: #{stderr.presence || status.exitstatus}" unless status.success?

      snapshot.prepared_workspace_archive.purge
      File.open(archive_path, "rb") do |archive|
        snapshot.prepared_workspace_archive.attach(
          io: archive,
          filename: "prepared.tar.gz",
          content_type: ImmutableSourceCheckout::PREPARED_ARCHIVE_CONTENT_TYPE,
          metadata: metadata
        )
      end
    end
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
