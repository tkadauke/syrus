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

  it "fails loudly on invalid explicit prepare config without recording a prepared cache" do
    update_remote_config("prepare: bundle install\n")
    checkout = described_class.new(step)

    expect { checkout.setup }
      .to raise_error(Steps::Base::StepFailed, /invalid prepare configuration.*must be an array/)

    cache_details = step.reload.details.fetch("prepare_cache")
    expect(cache_details).to include(
      "status" => "miss",
      "prepare_source" => ".syrus.yml",
      "command_count" => 0
    )
    expect(checkout.path.join(described_class::PREPARED_MARKER)).not_to exist
    expect(Pathname.new(cache_details.fetch("cache_path")).join(described_class::PREPARED_MARKER)).not_to exist
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

  it "mounts an overlay workspace from a prepared cache when the grader fan-out overlay flag is enabled" do
    enable_grader_fanout_overlay!
    described_class.new(step).setup
    first_cache_details = step.reload.details.fetch("prepare_cache")

    second_checkout = described_class.new(second_step)
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount) do |lower_path:, mount_path:, log:|
      copy_tree(lower_path, mount_path)
      log.call("[immutable_source_checkout] overlay workspace mounted in spec")
      ImmutableSourceCheckoutOverlay::Result.new(
        true,
        nil,
        lower_path.to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "upper").to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "work").to_s,
        mount_path.to_s
      )
    end
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout.setup

    # A published cache entry is a symlink to the concrete
    # `.<name>.version-<pid>-<hex>` directory PrepareCache#store_from! built,
    # so the overlay mounts -- and records -- the version it resolved to rather
    # than the symlink that names it. Pinning the resolved directory is the
    # point of publishing atomically: the symlink can be repointed under a
    # reader, the directory it resolved to cannot.
    # Resolve only the symlink itself, not the whole path: realpath would also
    # rewrite macOS's /var -> /private/var and stop matching what the code saw.
    published = Pathname.new(first_cache_details.fetch("cache_path"))
    resolved_cache_path = published.dirname.join(File.readlink(published))

    expect(ImmutableSourceCheckoutOverlay).to have_received(:mount).with(
      lower_path: resolved_cache_path,
      mount_path: second_checkout.path,
      log: anything
    )
    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_step.reload.details.fetch("immutable_source_workspace")).to include(
      "strategy" => "overlay",
      "lower_path" => resolved_cache_path.to_s,
      "mount_path" => second_checkout.path.to_s
    )
    expect(second_step.reload.details.fetch("prepare_cache")).to include("status" => "hit")
    expect(ProcessRunner).not_to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "falls back to a byte-identical hardlinked tree and records the overlay reason when mounting is unavailable" do
    described_class.new(step).setup
    # As in the overlay-mount example above: the published cache entry is a
    # symlink, and the code works with the concrete version directory it
    # resolves to. Resolve the link itself rather than calling realpath, which
    # would also rewrite macOS /var -> /private/var.
    published_cache_path = Pathname.new(step.reload.details.dig("prepare_cache", "cache_path"))
    cache_path = published_cache_path.dirname.join(File.readlink(published_cache_path))

    copy_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 3,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => snapshot.id }
    )
    copy_checkout = described_class.new(copy_step)
    copy_checkout.setup
    expected_manifest = checkout_manifest(copy_checkout.path)

    enable_grader_fanout_overlay!
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount).and_return(
      ImmutableSourceCheckoutOverlay::Result.new(
        false,
        "overlayfs is not listed in /proc/filesystems",
        cache_path.to_s,
        nil,
        nil,
        described_class.path_for(second_step).to_s
      )
    )

    fallback_checkout = described_class.new(second_step)
    fallback_checkout.setup

    expect(fallback_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(checkout_manifest(fallback_checkout.path)).to eq(expected_manifest)
    # Hard links, not a byte copy: the tree is ~69,000 entries and copying it
    # per grader is what made a graded landing attempt slow. The manifest above
    # is what "byte-identical" has to mean here, and links satisfy it.
    expect(second_step.reload.details.fetch("immutable_source_workspace")).to include(
      "strategy" => "hardlink",
      "fallback_reason" => "overlayfs is not listed in /proc/filesystems",
      "lower_path" => cache_path.to_s,
      "mount_path" => fallback_checkout.path.to_s
    )
    expect(File.stat(fallback_checkout.path.join("README.md")).ino)
      .to eq(File.stat(cache_path.join("README.md")).ino)
  end

  it "keeps overlay materialization diagnostics scoped to each grader Run across retries" do
    described_class.new(step).setup
    # As in the overlay-mount example above: the published cache entry is a
    # symlink, and the code works with the concrete version directory it
    # resolves to. Resolve the link itself rather than calling realpath, which
    # would also rewrite macOS /var -> /private/var.
    published_cache_path = Pathname.new(step.reload.details.dig("prepare_cache", "cache_path"))
    cache_path = published_cache_path.dirname.join(File.readlink(published_cache_path))
    enable_grader_fanout_overlay!
    retry_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 3,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => snapshot.id }
    )

    first_run = retry_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount) do |lower_path:, mount_path:, log:|
      copy_tree(lower_path, mount_path)
      log.call("[immutable_source_checkout] overlay workspace mounted in spec")
      ImmutableSourceCheckoutOverlay::Result.new(
        true,
        nil,
        lower_path.to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "upper").to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "work").to_s,
        mount_path.to_s
      )
    end

    first_checkout = described_class.new(retry_step, run: first_run)
    first_checkout.setup

    FileUtils.rm_rf(first_checkout.path)
    second_run = retry_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount).and_return(
      ImmutableSourceCheckoutOverlay::Result.new(
        false,
        "overlayfs is not listed in /proc/filesystems",
        cache_path.to_s,
        nil,
        nil,
        described_class.path_for(retry_step).to_s
      )
    )

    described_class.new(retry_step, run: second_run).setup

    first_log = materialization_log_for(first_run)
    second_log = materialization_log_for(second_run)
    expect(JSON.parse(first_log.delete_prefix("[immutable_source_workspace] "))).to include(
      "strategy" => "overlay",
      "lower_path" => cache_path.to_s
    )
    expect(JSON.parse(second_log.delete_prefix("[immutable_source_workspace] "))).to include(
      "strategy" => "hardlink",
      "fallback_reason" => "overlayfs is not listed in /proc/filesystems",
      "lower_path" => cache_path.to_s
    )
    expect(retry_step.reload.details.fetch("immutable_source_workspace")).to include(
      "strategy" => "hardlink",
      "fallback_reason" => "overlayfs is not listed in /proc/filesystems"
    )
  end

  it "publishes prepare cache replacements without exposing a missing checkout to readers" do
    cache = test_prepare_cache
    source = Dir.mktmpdir("syrus-prepare-cache-source")
    File.write(File.join(source, "sentinel.txt"), "old\n")
    cache.store_from!(source)
    File.write(File.join(source, "sentinel.txt"), "new\n")

    observed_missing = Concurrent::AtomicBoolean.new(false)
    stop_reader = Concurrent::AtomicBoolean.new(false)
    reader = Thread.new do
      until stop_reader.true?
        observed_missing.make_true unless cache.path.join("sentinel.txt").file?
      end
    end

    allow(FileUtils).to receive(:rm_rf).and_wrap_original do |original, target, *args, **kwargs|
      result = if kwargs.empty?
        original.call(target, *args)
      else
        original.call(target, *args, **kwargs)
      end
      sleep 0.05 if target.to_s == cache.path.to_s
      result
    end

    cache.store_from!(source)
    stop_reader.make_true
    reader.join

    expect(cache.path.join("sentinel.txt").read).to eq("new\n")
    expect(observed_missing.true?).to be(false)
  ensure
    stop_reader&.make_true
    reader&.join
    FileUtils.rm_rf(source) if source
  end

  it "replaces an existing prepare cache entry without nesting the new tree inside the old path" do
    cache = test_prepare_cache
    first_source = Dir.mktmpdir("syrus-prepare-cache-first")
    second_source = Dir.mktmpdir("syrus-prepare-cache-second")
    File.write(File.join(first_source, "sentinel.txt"), "old\n")
    File.write(File.join(second_source, "sentinel.txt"), "new\n")
    File.write(File.join(second_source, "fresh.txt"), "fresh\n")

    cache.store_from!(first_source)
    cache.store_from!(second_source)

    expect(cache.path.join("sentinel.txt").read).to eq("new\n")
    expect(cache.path.join("fresh.txt").read).to eq("fresh\n")
    expect(cache.path.children.map { |child| child.basename.to_s }).to contain_exactly("fresh.txt", "sentinel.txt")
  ensure
    FileUtils.rm_rf(first_source) if first_source
    FileUtils.rm_rf(second_source) if second_source
  end

  it "atomically replaces a legacy directory cache entry without exposing a missing path" do
    # The atomic swap uses renameat2/RENAME_EXCHANGE, which is Linux-only.
    # Workers run Linux; a developer machine cannot exercise this path, and
    # asserting it there only produces a failure nobody can act on.
    skip "renameat2 RENAME_EXCHANGE is Linux-only" unless RbConfig::CONFIG["host_os"].to_s.include?("linux")
    cache = test_prepare_cache
    source = Dir.mktmpdir("syrus-prepare-cache-source")
    FileUtils.mkdir_p(cache.path)
    File.write(cache.path.join("sentinel.txt"), "old\n")
    File.write(File.join(source, "sentinel.txt"), "new\n")

    observed_missing = Concurrent::AtomicBoolean.new(false)
    stop_reader = Concurrent::AtomicBoolean.new(false)
    reader = Thread.new do
      until stop_reader.true?
        observed_missing.make_true unless cache.path.join("sentinel.txt").file?
      end
    end

    allow(File).to receive(:rename).and_wrap_original do |original, old_path, new_path|
      result = original.call(old_path, new_path)
      sleep 0.05 if old_path.to_s == cache.path.to_s
      result
    end

    cache.store_from!(source)
    stop_reader.make_true
    reader.join

    expect(cache.path).to be_symlink
    expect(cache.path.join("sentinel.txt").read).to eq("new\n")
    expect(observed_missing.true?).to be(false)
  ensure
    stop_reader&.make_true
    reader&.join
    FileUtils.rm_rf(source) if source
  end

  it "retries prepare cache publication when a source entry disappears during the copy walk" do
    cache = test_prepare_cache
    source = Dir.mktmpdir("syrus-prepare-cache-source")
    File.write(File.join(source, "sentinel.txt"), "ready\n")
    calls = 0
    allow(FileUtils).to receive(:cp_r).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise Errno::ENOENT, "vanished" if calls == 1

      kwargs.empty? ? original.call(*args) : original.call(*args, **kwargs)
    end

    cache.store_from!(source)

    expect(calls).to eq(2)
    expect(cache.path.join("sentinel.txt").read).to eq("ready\n")
  ensure
    FileUtils.rm_rf(source) if source
  end

  it "preserves root symlinks when restoring a local prepare cache" do
    first_checkout = described_class.new(step)
    first_checkout.setup
    FileUtils.rm_rf(first_checkout.path)

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    link = second_checkout.path.join("AGENTS.md")
    expect(link).to be_symlink
    expect(link.readlink.to_s).to eq("CLAUDE.md")
    expect(second_step.reload.details.dig("prepare_cache", "status")).to eq("hit")
  end

  it "does not restore a legacy prepare cache that may have dereferenced root symlinks" do
    first_checkout = described_class.new(step)
    first_checkout.setup
    cache_path = Pathname.new(step.reload.details.dig("prepare_cache", "cache_path"))
    marker_path = cache_path.join(described_class::PREPARED_MARKER)
    marker = JSON.parse(marker_path.read).except("prepare_cache_format_version")
    marker_path.write(JSON.pretty_generate(marker))
    FileUtils.rm_f(cache_path.join("AGENTS.md"))
    File.write(cache_path.join("AGENTS.md"), "dereferenced legacy copy\n")
    snapshot.reload.prepared_workspace_archive.purge
    FileUtils.rm_rf(first_checkout.path)

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    expect(second_checkout.path.join("AGENTS.md")).to be_symlink
    expect(second_step.reload.details.dig("prepare_cache", "status")).to eq("miss")
  end

  it "invalidates a local prepare cache whose marker claims missing Node package binaries" do
    plan = instance_double(
      RepoPrepPlan::Result,
      source: ".syrus.yml",
      note: nil,
      guessed?: false,
      error?: false,
      commands: [
        <<~BASH.squish
          mkdir -p node_modules/typescript node_modules/.bin .syrus/deps/bundle &&
          printf '{"scripts":{"typecheck":"tsc --noEmit"}}' > package.json &&
          printf '{"packages":{"":{"devDependencies":{"typescript":"1.0.0"}},"node_modules/typescript":{"bin":{"tsc":"bin/tsc","tsserver":"bin/tsserver"}}}}' > package-lock.json &&
          printf '{"name":"typescript","bin":{"tsc":"bin/tsc","tsserver":"bin/tsserver"}}' > node_modules/typescript/package.json &&
          printf '#!/bin/sh\\n' > node_modules/.bin/tsc &&
          printf '#!/bin/sh\\n' > node_modules/.bin/tsserver &&
          chmod +x node_modules/.bin/tsc node_modules/.bin/tsserver &&
          printf 'ready\\n' > .syrus/deps/bundle/prepared.txt
        BASH
      ]
    )
    allow(RepoPrepPlan).to receive(:for).and_return(plan)

    described_class.new(step).setup
    cache_path = Pathname.new(step.reload.details.fetch("prepare_cache").fetch("cache_path"))
    snapshot.reload.prepared_workspace_archive.purge
    FileUtils.rm_rf(cache_path.join("node_modules/typescript"))
    FileUtils.rm_f(cache_path.join("node_modules/.bin/tsc"))
    FileUtils.rm_f(cache_path.join("node_modules/.bin/tsserver"))
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    expect(second_step.reload.details.fetch("prepare_cache")).to include("status" => "miss")
    expect(second_checkout.path.join("node_modules/.bin/tsc")).to exist
    expect(ProcessRunner).to have_received(:new).with(hash_including(kind: "prepare"))
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

  # The point of keying the layer by prepare fingerprint: the dependency
  # closure is identical across revisions (production saw 2 distinct
  # fingerprints in 14 days against 89 archives), so a second revision reuses
  # the cached tree and checks its own source out on top, instead of
  # downloading another 526 MB archive and untarring 1.6 GB of mostly
  # identical bytes.
  it "serves a different revision from the cached layer instead of downloading its archive" do
    enable_grader_fanout_overlay!
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount).and_return(
      ImmutableSourceCheckoutOverlay::Result.new(false, "overlayfs is not listed in /proc/filesystems", nil, nil, nil, nil)
    )
    described_class.new(step).setup
    first_archive = snapshot.reload.prepared_workspace_archive
    expect(first_archive).to be_attached
    # A fresh worker storage root takes the archive path -- the local prepare
    # cache belongs to the storage that built it -- so this is the checkout
    # that downloads the archive and populates the layer. It now sits at
    # main's revision.
    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    described_class.new(second_step).setup

    feature_snapshot = WorkflowSourceSnapshots.record!(
      workflow: workflow,
      creator_step: creator_step,
      source_sha: feature_sha,
      source_ref: "refs/syrus/source-snapshots/runs/123",
      tree_sha: feature_tree_sha
    )
    # The same dependency layer, offered to the next revision: one blob, its
    # metadata describing the revision that is asking for it.
    feature_snapshot.prepared_workspace_archive.attach(first_archive.blob)
    feature_snapshot.prepared_workspace_archive.blob.update!(
      metadata: first_archive.blob.metadata.merge(
        "source_snapshot_id" => feature_snapshot.id,
        "source_sha" => feature_sha,
        "source_ref" => "refs/syrus/source-snapshots/runs/123",
        "tree_sha" => feature_tree_sha
      )
    )
    feature_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 4,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => feature_snapshot.id }
    )
    allow(ProcessRunner).to receive(:new).and_call_original
    logs = []
    feature_checkout = described_class.new(feature_step, log: ->(message, **) { logs << message })

    feature_checkout.setup

    expect(logs.join("\n")).to include("prepared layer cache hit")
    expect(logs.join("\n")).to include("moving the checkout to #{feature_sha.first(9)}")
    expect(sh("git -C #{feature_checkout.path} rev-parse HEAD").strip).to eq(feature_sha)
    expect(feature_checkout.path.join("feature.txt")).to exist
    expect(feature_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(ProcessRunner).not_to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "preserves root symlinks when restoring a prepared archive on another worker" do
    described_class.new(step).setup
    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    link = second_checkout.path.join("AGENTS.md")
    expect(link).to be_symlink
    expect(link.readlink.to_s).to eq("CLAUDE.md")
    expect(second_step.reload.details.dig("prepare_cache", "status")).to eq("archive_hit")
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

  it "rejects a prepared archive from a different worker capability environment" do
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return(worker_environment("macos"))
    described_class.new(step).setup
    first_cache_details = step.reload.details.fetch("prepare_cache")
    expect(snapshot.reload.prepared_workspace_archive).to be_attached

    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return(worker_environment("linux"))
    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    allow(ProcessRunner).to receive(:new).and_call_original

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    second_cache_details = second_step.reload.details.fetch("prepare_cache")
    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_cache_details).to include(
      "status" => "miss",
      "worker_storage_key" => "storage-b",
      "source_snapshot_sha" => main_sha
    )
    expect(second_cache_details.fetch("prepare_fingerprint")).not_to eq(first_cache_details.fetch("prepare_fingerprint"))
    expect(ProcessRunner).to have_received(:new).with(hash_including(kind: "prepare"))
  end

  it "refreshes target fingerprints on the worker that executes the immutable grader" do
    stale_fingerprints = {
      "input_fingerprint" => "stale-input",
      "command_fingerprint" => "stale-command",
      "environment_fingerprint" => "stale-environment",
      "metadata" => { "worker_environment" => worker_environment("macos") }
    }
    step.update!(details: step.details.merge(
      "target_label" => "//:grade/backend",
      "target_fingerprints" => stale_fingerprints
    ))
    update_remote_config(<<~YAML)
      prepare:
        - mkdir -p "$BUNDLE_PATH" && printf 'ready\\n' > "$BUNDLE_PATH/prepared.txt"
      grade:
        - name: backend
          run: bin/test
          capabilities:
            os: linux
    YAML
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return(worker_environment("linux"))

    described_class.new(step).setup

    refreshed = step.reload.details.fetch("target_fingerprints")
    expect(refreshed).not_to eq(stale_fingerprints)
    expect(refreshed.dig("metadata", "worker_environment", "capabilities")).to eq("os" => [ "linux" ])
    expect(refreshed.fetch("environment_fingerprint")).to match(/\A[0-9a-f]{64}\z/)
  end

  it "uses an overlay lower restored from the prepared archive on a fresh worker when enabled" do
    described_class.new(step).setup
    expect(snapshot.reload.prepared_workspace_archive).to be_attached

    File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-b\n")
    enable_grader_fanout_overlay!
    allow(GithubAuthenticatedGit).to receive(:run).and_raise("unexpected remote fetch")
    allow(ImmutableSourceCheckoutOverlay).to receive(:mount) do |lower_path:, mount_path:, log:|
      copy_tree(lower_path, mount_path)
      log.call("[immutable_source_checkout] overlay workspace mounted in spec")
      ImmutableSourceCheckoutOverlay::Result.new(
        true,
        nil,
        lower_path.to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "upper").to_s,
        mount_path.dirname.join(".#{mount_path.basename}.overlay", "work").to_s,
        mount_path.to_s
      )
    end

    second_checkout = described_class.new(second_step)
    second_checkout.setup

    workspace_details = second_step.reload.details.fetch("immutable_source_workspace")
    expect(workspace_details).to include(
      "strategy" => "overlay",
      "mount_path" => second_checkout.path.to_s
    )
    expect(workspace_details.fetch("lower_path")).to include("/prepared-layers/storage-b/")
    expect(second_checkout.path.join(".syrus/deps/bundle/prepared.txt").read).to eq("ready\n")
    expect(second_step.reload.details.fetch("prepare_cache")).to include(
      "status" => "archive_hit",
      "worker_storage_key" => "storage-b",
      "source_snapshot_sha" => main_sha
    )
  end

  # 89 archives published in one production day against 2 distinct dependency
  # closures: what the archive holds is named by the prepare fingerprint, not
  # by the revision, so a second revision attaches the published blob instead
  # of uploading another ~526 MB copy of it.
  it "reuses a published archive for another revision with the same prepare fingerprint" do
    described_class.new(step).setup
    first_blob = snapshot.reload.prepared_workspace_archive.blob
    expect(snapshot.prepare_fingerprint).to be_present

    feature_snapshot = WorkflowSourceSnapshots.record!(
      workflow: workflow,
      creator_step: creator_step,
      source_sha: feature_sha,
      source_ref: "refs/syrus/source-snapshots/runs/123",
      tree_sha: feature_tree_sha
    )
    feature_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 6,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "source_snapshot_id" => feature_snapshot.id }
    )
    allow(PreparedWorkspaceArchive).to receive(:publish!).and_call_original

    described_class.new(feature_step).setup

    expect(feature_snapshot.reload.prepare_fingerprint).to eq(snapshot.prepare_fingerprint)
    expect(feature_snapshot.prepared_workspace_archive.blob).to eq(first_blob)
    expect(PreparedWorkspaceArchive).not_to have_received(:publish!)
  end

  # One blob backing many snapshots means purging it with a workflow would
  # delete the archive the others still point at.
  it "detaches rather than purges a prepared archive another snapshot shares" do
    described_class.new(step).setup
    blob = snapshot.reload.prepared_workspace_archive.blob
    sharer = WorkflowSourceSnapshots.record!(
      workflow: workflow,
      creator_step: creator_step,
      source_sha: feature_sha,
      source_ref: "refs/syrus/source-snapshots/runs/123",
      tree_sha: feature_tree_sha
    )
    sharer.prepared_workspace_archive.attach(blob)

    snapshot.purge_prepared_workspace_archive!

    expect(snapshot.reload.prepared_workspace_archive).not_to be_attached
    expect(sharer.reload.prepared_workspace_archive).to be_attached
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)

    sharer.purge_prepared_workspace_archive!

    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
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
      error?: false,
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
      File.write(File.join(seed, "CLAUDE.md"), "agent guide\n")
      File.symlink("CLAUDE.md", File.join(seed, "AGENTS.md"))
      File.write(File.join(seed, ".syrus.yml"), <<~YAML)
        prepare:
          - mkdir -p "$BUNDLE_PATH" && printf 'ready\\n' > "$BUNDLE_PATH/prepared.txt"
      YAML
      sh("git -C #{seed} add README.md CLAUDE.md AGENTS.md .syrus.yml")
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

  def update_remote_config(contents)
    Dir.mktmpdir("syrus-immutable-source-update") do |seed|
      sh("git clone -q #{bare_remote_dir} #{seed}")
      File.write(File.join(seed, ".syrus.yml"), contents)
      sh("git -C #{seed} add .syrus.yml")
      sh("git -C #{seed} commit -q -m 'update config' --author='Seed <s@e>'")
      sh("git -C #{seed} push -q origin HEAD:main")
    end
    @main_sha = nil
    @main_tree_sha = nil
    snapshot.update!(
      source_sha: main_sha,
      tree_sha: main_tree_sha
    )
  end

  def enable_grader_fanout_overlay!
    Feature.find_or_initialize_by(slug: "grader_fanout_overlay").tap do |feature|
      feature.category = "Operations"
      feature.name = "Grader fan-out overlay"
      feature.enabled = true
      feature.save!
    end
  end

  def copy_tree(source, destination)
    FileUtils.mkdir_p(destination)
    FileUtils.cp_r(
      Pathname.new(source).children.map(&:to_s),
      destination.to_s,
      preserve: true,
      dereference_root: false
    )
  end

  def checkout_manifest(root)
    root = Pathname.new(root)
    Dir.chdir(root) do
      Dir.glob("**/*", File::FNM_DOTMATCH)
        .reject { |path| path == "." || path.start_with?(".git/") }
        .sort
        .to_h do |relative_path|
          path = root.join(relative_path)
          payload = if path.symlink?
            "symlink:#{path.readlink}"
          elsif path.file?
            "file:#{Digest::SHA256.file(path).hexdigest}"
          elsif path.directory?
            "dir"
          else
            "other"
          end
          [ relative_path, payload ]
        end
    end
  end

  def materialization_log_for(run)
    run.job_logs.where(kind: "system").pluck(:chunk).find { |chunk| chunk.start_with?("[immutable_source_workspace]") }
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

  def worker_environment(os)
    {
      "capabilities" => { "os" => [ os ] },
      "runtime" => { "ruby_platform" => "#{os}-ruby" },
      "tool_versions" => { "ruby" => "ruby 3.4.10" }
    }
  end

  def test_prepare_cache
    plan = instance_double(
      RepoPrepPlan::Result,
      source: ".syrus.yml",
      note: nil,
      guessed?: false,
      error?: false,
      commands: [ "true" ]
    )
    described_class::PrepareCache.new(
      workflow: workflow,
      step: step,
      snapshot: snapshot,
      plan: plan,
      worker_storage_key: WorkerStorageIdentity.queue_key
    )
  end
end
