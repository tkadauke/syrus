require "rails_helper"
require "rubygems/package"
require "zlib"
require "digest"
require "stringio"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Builds::IsolatedBuilder do
  let(:data_root) { Pathname.new(Dir.mktmpdir("rib-spec")) }
  after { FileUtils.rm_rf(data_root) }

  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: SyntheticRuntimeImageProvider.new.key) }
  let(:orchestrator) { RuntimeImages::Builds::Orchestrator.new }
  let(:control) { instance_double(RuntimeImages::Builds::Runner::Control, cancel_requested?: false, heartbeat: true, raise_if_canceled!: nil) }
  let(:result_class) { ProcessRunner::Result }

  def tar_gz(files, links: {})
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        files.each { |name, body| tar.add_file_simple(name, 0o644, body.bytesize) { |f| f.write(body) } }
        links.each { |name, target| tar.add_symlink(name, target, 0o777) }
      end
    end
    io.string
  end

  def source_for(bytes, context: ".")
    RuntimeImages::Builds::SourceCapture.capture(kind: "archive", ref: "upload://1", revision: "sha256:#{Digest::SHA256.hexdigest(bytes)}", context_path: context)
  end

  def request_for(files, recipe: {}, context: ".", links: {}, bytes: nil)
    bytes ||= tar_gz(files, links: links)
    orchestrator.submit(namespace: namespace, source: source_for(bytes, context: context), recipe: recipe, platform: "linux/amd64",
                        requester_kind: "test", requester_ref: "1",
                        source_archive: { io: StringIO.new(bytes), filename: "src.tar.gz" })
  end

  def oci_layout(platform: "linux/amd64")
    blob = ->(b) { [ "sha256:#{Digest::SHA256.hexdigest(b)}", b ] }
    layer_digest, layer = blob.call("layer")
    config_digest, config = blob.call("{}")
    manifest_digest, manifest = blob.call(JSON.generate("schemaVersion" => 2, "config" => { "digest" => config_digest }, "layers" => [ { "digest" => layer_digest } ]))
    os, arch = platform.split("/")
    index = JSON.generate("manifests" => [ { "digest" => manifest_digest, "platform" => { "os" => os, "architecture" => arch } } ])
    io = StringIO.new
    Gem::Package::TarWriter.new(io) do |tar|
      { "index.json" => index, "blobs/sha256/#{layer_digest.split(":").last}" => layer, "blobs/sha256/#{config_digest.split(":").last}" => config,
        "blobs/sha256/#{manifest_digest.split(":").last}" => manifest }.each { |n, b| tar.add_file_simple(n, 0o644, b.bytesize) { |f| f.write(b) } }
    end
    io.string
  end

  def ok = result_class.new(exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: nil)

  # Records every invocation; the push step writes the OCI archive buildah would.
  def launcher(archive: oci_layout, calls: [], result: ok, &hook)
    lambda do |command:, env:, mounts:, timeout:, resource_limits:, stop_requested:, on_output_chunk:|
      calls << { command: command, env: env, mounts: mounts, timeout: timeout, limits: resource_limits }
      hook&.call(command, on_output_chunk, stop_requested)
      script = command.last
      if archive && (m = script.match(/oci-archive:(\S+)/))
        File.binwrite(m[1], archive)
      end
      result
    end
  end

  let(:open_confinement) { instance_double(described_class::Confinement, verify!: nil, verify_applied!: nil) }

  def builder(**opts)
    described_class.new(launcher: opts.delete(:launcher) || launcher, data_root: data_root,
                        confinement: opts.delete(:confinement) || open_confinement, **opts)
  end

  def build(request, b = builder) = b.build(request: request, attempt: nil, control: control)

  it "builds an OCI payload, attests the captured source, and never exposes credentials or sockets" do
    calls = []
    request = request_for({ "Dockerfile" => "FROM scratch\n" })
    ENV["GITHUB_TOKEN"] = "ghp_secret"
    output = build(request, builder(launcher: launcher(calls: calls)))

    expect(output.source_digest).to eq(request.source_digest)
    expect(output.payload[:blobs].size).to eq(2)
    expect(output.provenance).to include("builder" => "buildah-rootless", "isolation" => "chroot")

    env = calls.first[:env]
    expect(env.keys).to match_array(%w[PATH HOME TMPDIR LANG REGISTRY_AUTH_FILE DOCKER_CONFIG])
    expect(env.values.join).not_to include("ghp_secret")
    all = calls.flat_map { |c| c[:command] + c[:mounts].declared_mounts.map(&:host_path) }
    expect(all.join(" ")).not_to match(/docker\.sock|DOCKER_HOST/)
    expect(calls.first[:command].last).to include("--isolation chroot", "--memory", "--cpu-quota", "--ulimit")
    expect(calls.first[:limits].memory_max).to eq(RuntimeImages::Builds::Config.build_memory_bytes)
  ensure
    ENV.delete("GITHUB_TOKEN")
  end

  it "gives every build its own bounded tmpfs storage root, never shared across builds or namespaces" do
    calls = []
    other = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: namespace.provider_key)
    build(request_for({ "Dockerfile" => "FROM scratch\n" }), builder(launcher: launcher(calls: calls)))
    bytes = tar_gz({ "Dockerfile" => "FROM scratch\n# other\n" })
    second = orchestrator.submit(namespace: other, source: source_for(bytes), recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "2",
                                 source_archive: { io: StringIO.new(bytes), filename: "s.tgz" })
    build(second, builder(launcher: launcher(calls: calls)))

    roots = calls.map { |c| c[:command].last[%r{--root (\S+)}, 1] }
    expect(roots.uniq.size).to eq(2)
    expect(calls.map { |c| c[:command].last }).to all(include("mount -t tmpfs -o size=#{RuntimeImages::Builds::Config.build_storage_bytes}"))
  end

  it "passes only validated build args and target" do
    calls = []
    request = request_for({ "Dockerfile" => "FROM scratch\n" }, recipe: { "target" => "prod", "build_args" => { "FOO" => "bar" } })
    build(request, builder(launcher: launcher(calls: calls)))
    expect(calls.first[:command].last).to include("--target prod", "--build-arg FOO\\=bar")
  end

  describe "path validation" do
    it "rejects a traversing Dockerfile path" do
      request = request_for({ "Dockerfile" => "x" }, recipe: { "dockerfile" => "../../etc/passwd" })
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("path_traversal"); expect(e.retryable).to be(false) }
    end

    it "rejects an absolute context path" do
      request = request_for({ "Dockerfile" => "x" }, recipe: { "context" => "/etc" })
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed, /relative/)
    end

    it "rejects a Dockerfile that is a symlink out of the source" do
      bytes = tar_gz({ "x" => "1" }, links: { "Dockerfile" => "../../outside" })
      expect { build(request_for({}, bytes: bytes)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("path_traversal") }
    end

    it "rejects archives containing traversing entries" do
      bytes = tar_gz({ "../evil" => "x", "Dockerfile" => "x" })
      expect { build(request_for({}, bytes: bytes)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("path_traversal") }
      expect(File.exist?(data_root.join("evil"))).to be(false)
    end

    it "rejects a missing Dockerfile" do
      expect { build(request_for({ "README" => "x" })) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("path_missing") }
    end

    it "rejects unknown recipe keys and malformed build args" do
      expect { build(request_for({ "Dockerfile" => "x" }, recipe: { "privileged" => true })) }.to raise_error(RuntimeImages::Builds::BuildFailed, /unsupported recipe keys/)
      expect { build(request_for({ "Dockerfile" => "x" }, recipe: { "build_args" => { "a b" => "1" } })) }.to raise_error(RuntimeImages::Builds::BuildFailed, /invalid build arg/)
    end

    it "rejects a sha256 source whose archive does not match the capture" do
      request = request_for({ "Dockerfile" => "x" })
      request.source_archive.attach(io: StringIO.new(tar_gz({ "Dockerfile" => "tampered" })), filename: "t.tgz")
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_mismatch") }
    end
  end

  describe "raw source archive size" do
    it "rejects an oversized raw archive before downloading it, even when its entries are small" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(request.source_archive.blob.byte_size - 1)
      expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end

    it "caps the streamed bytes when the recorded size understates the blob" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      blob = request.source_archive.blob
      allow(blob).to receive(:byte_size).and_return(1)
      allow(request.source_archive).to receive(:blob).and_return(blob)
      allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(5)
      allow(blob).to receive(:download).and_yield("x" * 4).and_yield("x" * 4)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end
  end

  describe "source footprint against the storage ceiling" do
    it "rejects an archive larger than a lower storage ceiling" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size - 1)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end

    it "rejects when raw archive plus extracted bytes cross the storage ceiling" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      raw = request.source_archive.blob.byte_size
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(raw + 5)
      expect { build(request, builder(extractor: RuntimeImages::Builds::SourceExtractor.new)) }
        .to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end
  end

  describe "ceilings" do
    let(:request) { request_for({ "Dockerfile" => "FROM scratch\n" }) }

    it "stops the build and fails when the log volume ceiling is passed" do
      allow(RuntimeImages::Builds::Config).to receive(:build_log_bytes).and_return(10)
      l = launcher { |_c, on_chunk, _stop| on_chunk.call("x" * 50) }
      expect { build(request, builder(launcher: l)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("log_limit_exceeded") }
    end

    it "fails when scratch storage exceeds its ceiling" do
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size + 20)
      l = launcher { |_c, _chunk, stop| File.binwrite(File.join(File.dirname(File.dirname(Dir.glob("#{data_root}/runtime-image-builds/builds/*/source").first)), "big"), "x" * 100) rescue nil; stop.call }
      expect { build(request, builder(launcher: l)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("storage_limit_exceeded") }
    end

    it "fails when the output image is over its ceiling" do
      allow(RuntimeImages::Builds::Config).to receive(:max_output_bytes).and_return(10)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("output_too_large") }
    end

    it "fails on timeout and non-zero exit" do
      timed_out = ok.with(timed_out: true, exit_status: nil)
      expect { build(request, builder(launcher: launcher(result: timed_out))) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("build_timeout") }
      failed = ok.with(exit_status: 1)
      expect { build(request, builder(launcher: launcher(result: failed))) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("build_failed") }
    end

    it "rejects oversized sources" do
      allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(3)
      expect { build(request_for({ "Dockerfile" => "FROM scratch\n" }), builder(extractor: RuntimeImages::Builds::SourceExtractor.new)) }
        .to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end
  end

  it "reports a corrupt output archive as a non-retryable failure" do
    request = request_for({ "Dockerfile" => "x" })
    expect { build(request, builder(launcher: launcher(archive: "not a tar"))) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("output_invalid") }
  end

  it "maps cancellation to the control's cancel" do
    allow(control).to receive(:raise_if_canceled!).and_raise(RuntimeImages::Builds::Canceled)
    expect { build(request_for({ "Dockerfile" => "x" })) }.to raise_error(RuntimeImages::Builds::Canceled)
  end

  describe "confinement and hard ceilings" do
    let(:request) { request_for({ "Dockerfile" => "FROM scratch\n" }) }

    it "runs build and push as one command in a private user+mount namespace under prlimit" do
      calls = []
      build(request, builder(launcher: launcher(calls: calls)))
      expect(calls.size).to eq(1)
      cmd = calls.first[:command]
      expect(cmd.first(2)).to eq([ "prlimit", "--nproc=#{RuntimeImages::Builds::Config.build_pids}" ])
      expect(cmd).to include("--fsize=#{[ RuntimeImages::Builds::Config.build_storage_bytes, RuntimeImages::Builds::Config.max_output_bytes ].max}")
      expect(cmd.each_cons(4).to_a).to include(%w[unshare --user --map-root-user --mount])
      expect(cmd.last).to match(/mount -t tmpfs -o size=\d+,mode=0700 tmpfs .* build .* && .* push /)
    end

    it "keeps layer storage, HOME and TMPDIR on the bounded tmpfs" do
      calls = []
      build(request, builder(launcher: launcher(calls: calls)))
      work = calls.first[:command].last[%r{--root (\S+)/storage}, 1]
      env = calls.first[:env]
      expect(env["HOME"]).to start_with(work)
      expect(env["TMPDIR"]).to start_with(work)
    end

    it "rejects storage overshoot found after the command exits, without any poll" do
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size + 20)
      l = launcher
      l2 = lambda do |command:, env:, **rest|
        File.binwrite(File.join(File.dirname(env["HOME"]), "..", "big"), "x" * 100)
        l.call(command: command, env: env, **rest)
      end
      expect { build(request, builder(launcher: l2)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("storage_limit_exceeded") }
    end

    it "fails closed when a bounded tmpfs namespace cannot be created" do
      allow(Process).to receive(:euid).and_return(1000)
      c = described_class::Confinement.new
      allow(c).to receive(:system).and_return(true, false)
      expect { c.verify! }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("builder_not_isolated") }
    end

    it "accepts the confinement probe when prlimit and the tmpfs namespace work" do
      allow(Process).to receive(:euid).and_return(1000)
      c = described_class::Confinement.new
      allow(c).to receive(:system).and_return(true, true)
      expect { c.verify! }.not_to raise_error
    end

    it "fails closed as root without a confinement attestation" do
      allow(Process).to receive(:euid).and_return(0)
      expect { build(request, builder(confinement: described_class::Confinement.new)) }
        .to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("builder_not_isolated") }
    end

    it "fails when cgroup limits were not applied to the spawned process" do
      process = instance_double(SpawnedProcess, resource_attribution: { "cgroup" => { "state" => "unavailable" } })
      allow(SpawnedProcess).to receive(:find_by).with(id: 7).and_return(process)
      res = result_class.new(exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: 7)
      expect { described_class::Confinement.new.verify_applied!(res) }
        .to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("builder_not_isolated") }
    end

    it "fails closed when the command left no spawned-process record (never ran in a cgroup)" do
      res = result_class.new(exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: nil)
      expect { described_class::Confinement.new.verify_applied!(res) }
        .to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("builder_not_isolated") }
    end

    it "accepts a command whose cgroup was applied" do
      process = instance_double(SpawnedProcess, resource_attribution: { "cgroup" => { "state" => "applied" } })
      allow(SpawnedProcess).to receive(:find_by).with(id: 7).and_return(process)
      res = result_class.new(exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: 7)
      expect { described_class::Confinement.new.verify_applied!(res) }.not_to raise_error
    end

    it "asks for a PID ceiling in the per-spawn cgroup limits" do
      calls = []
      build(request, builder(launcher: launcher(calls: calls)))
      expect(calls.map { |c| c[:limits].pids_max }.uniq).to eq([ RuntimeImages::Builds::Config.build_pids ])
    end

    it "runs the default launcher as a registered builder spawn so a cgroup is created" do
      runner = instance_double(ProcessRunner, run: :result)
      expect(ProcessRunner).to receive(:new).with(hash_including(kind: "builder")).and_return(runner)
      out = described_class::Launcher.new("prepare").call(command: [ "true" ], env: {}, mounts: nil, timeout: 1,
                                                          resource_limits: nil, stop_requested: -> { false }, on_output_chunk: nil)
      expect(out).to eq(:result)
    end
  end
end
