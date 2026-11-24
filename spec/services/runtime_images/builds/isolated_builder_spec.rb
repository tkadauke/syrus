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
      File.binwrite(command.last.delete_prefix("oci-archive:"), archive) if command.include?("push") && archive
      result
    end
  end

  def builder(**opts) = described_class.new(launcher: opts.delete(:launcher) || launcher, data_root: data_root, **opts)

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
    expect(calls.first[:command]).to include("--isolation", "chroot", "--memory", "--cpu-quota", "--ulimit")
    expect(calls.first[:limits].memory_max).to eq(RuntimeImages::Builds::Config.build_memory_bytes)
  ensure
    ENV.delete("GITHUB_TOKEN")
  end

  it "isolates layer caches per namespace" do
    calls = []
    other = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: namespace.provider_key)
    build(request_for({ "Dockerfile" => "FROM scratch\n" }), builder(launcher: launcher(calls: calls)))
    bytes = tar_gz({ "Dockerfile" => "FROM scratch\n# other\n" })
    second = orchestrator.submit(namespace: other, source: source_for(bytes), recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "2",
                                 source_archive: { io: StringIO.new(bytes), filename: "s.tgz" })
    build(second, builder(launcher: launcher(calls: calls)))

    roots = calls.map { |c| c[:command][c[:command].index("--root") + 1] }.uniq
    expect(roots.size).to eq(2)
    expect(roots.map { |r| r.split("/")[-2] }).to eq([ "ns-#{namespace.id}", "ns-#{other.id}" ])
  end

  it "passes only validated build args and target" do
    calls = []
    request = request_for({ "Dockerfile" => "FROM scratch\n" }, recipe: { "target" => "prod", "build_args" => { "FOO" => "bar" } })
    build(request, builder(launcher: launcher(calls: calls)))
    expect(calls.first[:command]).to include("--target", "prod", "--build-arg", "FOO=bar")
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

  describe "ceilings" do
    let(:request) { request_for({ "Dockerfile" => "FROM scratch\n" }) }

    it "stops the build and fails when the log volume ceiling is passed" do
      allow(RuntimeImages::Builds::Config).to receive(:build_log_bytes).and_return(10)
      l = launcher { |_c, on_chunk, _stop| on_chunk.call("x" * 50) }
      expect { build(request, builder(launcher: l)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("log_limit_exceeded") }
    end

    it "fails when scratch storage exceeds its ceiling" do
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(1)
      l = launcher { |_c, _chunk, stop| stop.call }
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

    it "backs off retryably when the namespace cache is in use" do
      cache = data_root.join("runtime-image-builds", "cache", "ns-#{namespace.id}")
      FileUtils.mkdir_p(cache)
      File.open(cache.join(".lock"), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect([ e.code, e.retryable ]).to eq([ "cache_busy", true ]) }
      end
    end

    it "wipes a cache that outgrew its ceiling" do
      cache = data_root.join("runtime-image-builds", "cache", "ns-#{namespace.id}")
      FileUtils.mkdir_p(cache.join("storage"))
      File.write(cache.join("storage", "big"), "x" * 100)
      allow(RuntimeImages::Builds::Config).to receive(:cache_max_bytes).and_return(10)
      build(request)
      expect(File.exist?(cache.join("storage", "big"))).to be(false)
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
end
