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
  let(:evidence) { RuntimeImages::Builds::Evidence.new }
  let(:control) { instance_double(RuntimeImages::Builds::Runner::Control, cancel_requested?: false, heartbeat: true, raise_if_canceled!: nil, evidence: evidence) }
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

  let(:extract_source) { true }

  # Records every invocation; the push step writes the OCI archive buildah would.
  def launcher(archive: oci_layout, calls: [], result: ok, &hook)
    lambda do |command:, env:, mounts:, timeout:, resource_limits:, stop_requested:, on_output_chunk:|
      calls << { command: command, env: env, mounts: mounts, timeout: timeout, limits: resource_limits }
      hook&.call(command, on_output_chunk, stop_requested)
      script = command.last
      # The real command extracts inside the bounded tmpfs namespace; here the
      # same script runs directly (no namespace) so path and archive
      # validation is exercised end to end.
      extract = script.split("; ").find { |part| part.include?("extract-runtime-image-source") }
      system(extract, exception: false) if extract && extract_source
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
    expect(env.keys).to match_array(%w[PATH HOME TMPDIR LANG REGISTRY_AUTH_FILE DOCKER_CONFIG] + RuntimeImages::BuildNetwork::Session.new(dir: "x", proxy: nil, policy: nil).environment.keys)
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
    sizes = calls.map { |c| c[:command].last[/mount -t tmpfs -o size=(\d+)/, 1].to_i }
    expect(sizes).to all(be_positive.and(be < RuntimeImages::Builds::Config.build_storage_bytes))
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

    # F137: a symlink's target was checked lexically from the path it was
    # written under, not from where that path really is. Through "d" -> ".",
    # "d/x" -> ".." looked like the root but was the root's parent.
    it "rejects a symlink that leaves the source through another symlink" do
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "a.tar")
        File.open(archive, "wb") do |io|
          Gem::Package::TarWriter.new(io) do |tar|
            tar.add_symlink("d", ".", 0o777)
            tar.add_symlink("d/x", "..", 0o777)
            tar.mkdir("d/x/escaped", 0o755)
          end
        end

        expect { RuntimeImages::Builds::SourceExtractor.new.extract(archive, File.join(dir, "dest")) }
          .to raise_error(RuntimeImages::Builds::Rejected) { |e| expect(e.code).to eq("path_traversal") }
        expect(File.exist?(File.join(dir, "escaped"))).to be(false)
      end
    end

    it "rejects a symlink whose target climbs out through another symlink" do
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "a.tar")
        File.open(archive, "wb") do |io|
          Gem::Package::TarWriter.new(io) do |tar|
            tar.add_symlink("d", ".", 0o777)
            tar.add_symlink("y", "d/..", 0o777)
          end
        end

        expect { RuntimeImages::Builds::SourceExtractor.new.extract(archive, File.join(dir, "dest")) }
          .to raise_error(RuntimeImages::Builds::Rejected) { |e| expect(e.code).to eq("path_traversal") }
      end
    end

    it "keeps a relative symlink that stays inside the source" do
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "a.tar")
        File.open(archive, "wb") do |io|
          Gem::Package::TarWriter.new(io) do |tar|
            tar.mkdir("shared", 0o755)
            tar.add_file_simple("shared/lib.rb", 0o644, 1) { |f| f.write("x") }
            tar.mkdir("app", 0o755)
            tar.add_symlink("app/lib", "../shared", 0o777)
          end
        end

        RuntimeImages::Builds::SourceExtractor.new.extract(archive, File.join(dir, "dest"))
        expect(File.read(File.join(dir, "dest", "app", "lib", "lib.rb"))).to eq("x")
      end
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

  describe "source extraction runs inside the bounded namespace" do
    it "unpacks the source from the command that mounts the size-bounded tmpfs, never on the host" do
      calls = []
      build(request_for({ "Dockerfile" => "FROM scratch\n" }), builder(launcher: launcher(calls: calls)))
      script = calls.first[:command].last
      mount = script.index("mount -t tmpfs")
      expect(mount).to be < script.index("extract-runtime-image-source")
      expect(script.index("extract-runtime-image-source")).to be < script.index(" build ")
      expect(Dir.glob(File.join(data_root, "runtime-image-builds", "**", "source"))).to be_empty
    end

    it "sizes the tmpfs from what the staged archive leaves, so archive plus tmpfs never exceed the ceiling" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      ceiling = 50_000_000
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(ceiling)
      allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(ceiling)
      calls = []
      build(request, builder(launcher: launcher(calls: calls)))
      size = calls.first[:command].last[/mount -t tmpfs -o size=(\d+)/, 1].to_i
      archive = request.source_archive.blob.byte_size
      expect(size).to be <= ceiling - archive
      expect(size).to be > 0
    end

    it "rejects a source whose archive leaves no room for the tmpfs within the ceiling" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size + 100)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end

    it "rejects an archive larger than a lower storage ceiling before it is written" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size - 1)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
    end

    it "reports ENOSPC from the bounded filesystem as an oversized source" do
      Dir.mktmpdir do |dir|
        archive = File.join(dir, "a.tgz")
        File.binwrite(archive, tar_gz({ "Dockerfile" => "x" }))
        allow(File).to receive(:open).and_call_original
        # The extractor writes under the destination's real path; on macOS the
        # temp dir is a symlink into /private, so stub the resolved path.
        allow(File).to receive(:open).with(File.join(File.realpath(dir), "dest", "Dockerfile"), "wb", anything).and_raise(Errno::ENOSPC)
        expect { RuntimeImages::Builds::SourceExtractor.new.extract(archive, File.join(dir, "dest")) }
          .to raise_error(RuntimeImages::Builds::Rejected) { |e| expect(e.code).to eq("source_too_large") }
      end
    end

    it "fails the build when the extraction step rejected the source, even though the command exited cleanly" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      allow(RuntimeImages::Builds::Config).to receive(:max_source_entries).and_return(0)
      expect { build(request) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("source_too_large") }
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
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size + 40_000)
      l = launcher { |_c, _chunk, stop| stop.call }
      l1 = l
      l = lambda do |command:, env:, **rest|
        File.binwrite(File.join(File.dirname(env["HOME"]), "..", "big"), "x" * 60_000)
        l1.call(command: command, env: env, **rest)
      end
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
      expect { build(request_for({ "Dockerfile" => "FROM scratch\n" })) }
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
      allow(RuntimeImages::Builds::Config).to receive(:build_storage_bytes).and_return(request.source_archive.blob.byte_size + 40_000)
      l = launcher
      l2 = lambda do |command:, env:, **rest|
        File.binwrite(File.join(File.dirname(env["HOME"]), "..", "big"), "x" * 60_000)
        l.call(command: command, env: env, **rest)
      end
      expect { build(request, builder(launcher: l2)) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("storage_limit_exceeded") }
    end

    it "fails closed when a bounded tmpfs namespace cannot be created" do
      allow(Process).to receive(:euid).and_return(1000)
      c = described_class::Confinement.new
      allow(c).to receive(:probe).and_return(true, false)
      expect { c.verify! }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("builder_not_isolated") }
    end

    it "accepts the confinement probe when prlimit, the tmpfs namespace and the cgroup work" do
      allow(Process).to receive(:euid).and_return(1000)
      allow(SpawnedProcessCgroup).to receive(:unenforceable_reason).with(pids: true).and_return(nil)
      c = described_class::Confinement.new
      allow(c).to receive(:probe).and_return(true, true, true)
      expect { c.verify! }.not_to raise_error
    end

    # F135: the memory/CPU/PID cgroup is checked before the build runs, not
    # only after it: an unconfined build would already have run by then, and
    # with the default flags every build would be rejected and retried forever.
    it "fails closed before the build when per-spawn cgroup limits cannot be applied" do
      allow(Process).to receive(:euid).and_return(1000)
      allow(RuntimeImages::Builds::Config).to receive(:cgroup_optional?).and_return(false)
      allow(Feature).to receive(:per_spawn_resource_limits_enabled?).and_return(false)
      c = described_class::Confinement.new
      allow(c).to receive(:probe).and_return(true, true, true)

      expect { c.verify! }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e|
        expect(e.code).to eq("builder_not_isolated")
        expect(e.retryable).to be(false)
        expect(e.message).to include("per_spawn_resource_limits")
      }
    end

    it "fails closed when an empty network namespace cannot be created" do
      allow(Process).to receive(:euid).and_return(1000)
      c = described_class::Confinement.new
      allow(c).to receive(:probe).and_return(true, true, false)
      expect { c.verify! }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e|
        expect(e.code).to eq("builder_not_isolated")
        expect(e.message).to include("network namespace")
      }
    end

    it "runs the build in an empty network namespace whose only route is the egress relay" do
      calls = []
      build(request, builder(launcher: launcher(calls: calls)))
      cmd = calls.first[:command]
      expect(cmd.each_cons(6).to_a).to include(%w[unshare --user --map-root-user --mount --net --])
      script = cmd.last
      expect(script).to include("ip link set lo up", "runtime-image-build-relay", "trap 'kill $relay")
      expect(script).not_to include("--network")
      env = calls.first[:env]
      expect(env.values_at("HTTP_PROXY", "HTTPS_PROXY", "http_proxy")).to all(eq("http://127.0.0.1:3128"))
      expect(env["NO_PROXY"]).to eq("")
      expect(calls.first[:mounts].declared_mounts.map(&:host_path).join(" ")).to match(%r{/rib})
    end

    it "records the network policy digest in provenance and audits denials" do
      RuntimeImageBuildNetworkRule.create!(source_class: "source_host", host: "github.com")
      output = build(request, builder(launcher: launcher))
      expect(output.provenance["network_policy_digest"]).to eq(RuntimeImages::BuildNetwork::Policy.current.digest)
      event = RuntimeImageAuditEvent.where(event_type: "build.network").last
      expect(event.outcome).to eq("ok")
      expect(event.details).to include("policy_digest" => output.provenance["network_policy_digest"], "denied" => 0)
    end

    it "audits the build's denied destinations even when the build fails" do
      allow(RuntimeImages::BuildNetwork::Session).to receive(:open).and_wrap_original do |original, **opts, &block|
        original.call(**opts) do |session|
          session.instance_variable_get(:@proxy).send(:record, RuntimeImages::BuildNetwork::Decision.deny("not_allowlisted", host: "evil.example", port: 443))
          block.call(session)
        end
      end
      failing = result_class.new(exit_status: 1, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: nil)
      expect { build(request, builder(launcher: launcher(result: failing))) }.to raise_error(RuntimeImages::Builds::BuildFailed)
      event = RuntimeImageAuditEvent.where(event_type: "build.network").last
      expect(event.outcome).to eq("detected")
      expect(event.details["denials"]).to be_an(Array)
      expect(event.details["denials"].to_json).to include("evil.example")
    end

    %w[network network_mode add_host dns proxy].each do |key|
      it "rejects a recipe that chooses its own #{key}" do
        req = request_for({ "Dockerfile" => "FROM scratch\n" }, recipe: { key => "host" })
        expect { build(req) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("network_mode_forbidden") }
      end
    end

    %w[HTTP_PROXY https_proxy NO_PROXY all_proxy].each do |name|
      it "rejects a build arg that overrides #{name}" do
        req = request_for({ "Dockerfile" => "FROM scratch\n" }, recipe: { "build_args" => { name => "http://evil" } })
        expect { build(req) }.to raise_error(RuntimeImages::Builds::BuildFailed) { |e| expect(e.code).to eq("network_mode_forbidden") }
      end
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

  describe "build evidence" do
    let(:version_probe) { -> { "buildah version 1.99.0; isolation=chroot; storage=vfs" } }
    let(:base_digest) { "sha256:#{"d" * 64}" }

    it "records the builder version, sanitized log, bases, policy snapshot, measurements, and output size" do
      RuntimeImageBuildNetworkRule.create!(source_class: "source_host", host: "github.com")
      request = request_for({ "Dockerfile" => "FROM docker.io/library/alpine:3.20 AS base\nFROM base\nFROM scratch\n" })
      process = SpawnedProcess.create!(
        kind: "builder", command: "buildah", hostname: "worker-1", started_at: 1.minute.ago, finished_at: Time.current, outcome: "succeeded",
        resource_attribution: { "cgroup" => { "state" => "applied", "memory_peak_bytes" => 12_345,
                                              "cpu_stat" => { "usage_usec" => 900, "user_usec" => 600, "system_usec" => 300 },
                                              "memory_events" => { "oom_kill" => 0 } } }
      )
      finished = result_class.new(exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false,
                                  aliveness_failed: false, duration_s: 4.5, spawned_process_id: process.id)
      launch = launcher(result: finished) do |command, on_output_chunk, _stop|
        script = command.last
        File.write(script[%r{> (\S+bases\.txt)}, 1], "FROM docker.io/library/alpine:3.20 AS base\n")
        File.write(script[%r{> (\S+images\.json)}, 1], JSON.generate([ { "names" => [ "docker.io/library/alpine:3.20" ], "digest" => base_digest } ]))
        on_output_chunk.call("STEP 1: Authorization: Bearer abcdefghijklmnop\npassword=hunter2 ok\n")
      end

      build(request, builder(launcher: launch, version_probe: version_probe))

      expect(evidence.builder_version).to eq("buildah version 1.99.0; isolation=chroot; storage=vfs")
      expect(evidence.base_images).to eq([ { "reference" => "docker.io/library/alpine:3.20", "pinned" => false, "digest" => base_digest } ])
      expect(evidence.policy_snapshot.map { |rule| rule["host"] }).to eq([ "github.com" ])
      expect(evidence.policy_digest).to start_with("sha256:")
      log = evidence.finalize_log
      expect(log).to include("STEP 1:", "[REDACTED]")
      expect(log).not_to include("abcdefghijklmnop", "hunter2")
      expect(evidence.resources["cgroup"]).to include("memory_peak_bytes" => 12_345, "cpu_usage_usec" => 900)
      expect(evidence.resources).to include("duration_seconds" => 4.5, "output_bytes" => be_positive, "peak_scratch_bytes" => be_a(Integer))
    end

    it "still records version, policy, and bases when the build fails" do
      request = request_for({ "Dockerfile" => "FROM scratch\n" })
      failing = result_class.new(exit_status: 1, timed_out: false, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 1, spawned_process_id: nil)
      launch = launcher(result: failing, archive: nil) do |command, on_output_chunk, _stop|
        File.write(command.last[%r{> (\S+bases\.txt)}, 1], "FROM busybox@sha256:#{"a" * 64}\n")
        on_output_chunk.call("boom\n")
      end

      expect { build(request, builder(launcher: launch, version_probe: version_probe)) }.to raise_error(RuntimeImages::Builds::BuildFailed)

      expect(evidence.builder_version).to include("1.99.0")
      expect(evidence.policy_digest).to start_with("sha256:")
      expect(evidence.base_images).to eq([ { "reference" => "busybox@sha256:#{"a" * 64}", "pinned" => true, "digest" => "sha256:#{"a" * 64}" } ])
      expect(evidence.finalize_log).to eq("boom\n")
    end

    it "records the reached destinations with resolved addresses" do
      summary = { "allowed" => 2, "denied" => 0,
                  "destinations" => [ { "host" => "github.com", "port" => 443, "address" => "140.82.1.1", "source_class" => "source_host", "count" => 2 } ] }
      policy = RuntimeImages::BuildNetwork::Policy.new([])
      evidence.record_network(policy, summary)
      expect(evidence.destinations.first).to include("address" => "140.82.1.1", "count" => 2)
      expect(evidence.resources["network"]).to eq("allowed" => 2, "denied" => 0)
    end
  end

  # Negative fixtures: with every kind of ambient authority present in the
  # worker's own environment, none of it may reach the build.
  describe "negative security fixtures" do
    AMBIENT = {
      "GITHUB_TOKEN" => "ghp_ambient", "DATABASE_URL" => "mysql2://root:dbpass@db/syrus", "RAILS_MASTER_KEY" => "masterkey123",
      "SECRET_KEY_BASE" => "sekb", "ANTHROPIC_API_KEY" => "sk-ant-ambient", "AWS_ACCESS_KEY_ID" => "AKIAAMBIENT",
      "AWS_SECRET_ACCESS_KEY" => "awssecret", "DOCKER_HOST" => "unix:///var/run/docker.sock", "CONTAINER_HOST" => "unix:///run/podman/podman.sock",
      "KUBECONFIG" => "/root/.kube/config", "KUBERNETES_SERVICE_HOST" => "10.43.0.1", "KUBERNETES_SERVICE_PORT" => "443",
      "SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_PASSWORD" => "regbuilderpw", "SYRUS_RUNTIME_IMAGE_REGISTRY_ADMIN_PASSWORD" => "regadminpw",
      "HTTP_PROXY" => "http://app-proxy.internal:3128", "ALL_PROXY" => "socks5://app-proxy.internal:1080",
      "REGISTRY_AUTH_FILE" => "/root/auth.json", "XDG_RUNTIME_DIR" => "/run/user/0", "SSH_AUTH_SOCK" => "/tmp/agent.sock"
    }.freeze

    around do |example|
      saved = AMBIENT.keys.to_h { |key| [ key, ENV[key] ] }
      AMBIENT.each { |key, value| ENV[key] = value }
      example.run
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    let(:calls) { [] }

    before { build(request_for({ "Dockerfile" => "FROM scratch\n" }), builder(launcher: launcher(calls: calls))) }

    it "passes none of the worker's credentials or endpoints into the build environment" do
      env = calls.first[:env]
      # Proxy and registry-auth variables exist but are rebuilt by the builder (checked below); every other ambient variable is dropped.
      AMBIENT.except("HTTP_PROXY", "ALL_PROXY", "REGISTRY_AUTH_FILE").each_key { |key| expect(env).not_to have_key(key) }
      expect(env.values.join(" ")).not_to match(/ghp_ambient|dbpass|masterkey123|sk-ant-ambient|awssecret|regbuilderpw|regadminpw|app-proxy\.internal|docker\.sock|podman\.sock/)
    end

    it "points proxy variables only at the in-namespace relay and the registry auth at an empty file" do
      env = calls.first[:env]
      expect(env.values_at("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")).to all(eq("http://127.0.0.1:3128"))
      expect(env["ALL_PROXY"]).to eq("http://127.0.0.1:3128")
      expect(env["REGISTRY_AUTH_FILE"]).not_to eq(AMBIENT["REGISTRY_AUTH_FILE"])
    end

    it "mounts nothing but the build's own scratch and relay directories, never a socket or credential path" do
      hosts = calls.flat_map { |c| c[:mounts].declared_mounts.map(&:host_path) }.map(&:to_s)
      expect(hosts).not_to be_empty
      # The build's scratch under the data root, plus the private directory holding only the proxy socket.
      expect(hosts).to all(start_with(data_root.to_s).or(match(%r{\A#{Regexp.escape(Dir.tmpdir)}/rib[^/]+\z})))
      expect(hosts.join(" ")).not_to match(%r{\.sock|/var/run|/run/|docker|containerd|podman|\.kube|serviceaccount|/etc/|/root|\.ssh|/proc|/sys|/dev/})
    end

    it "never runs the command with a host or shared network, device, or privilege flag" do
      command = calls.flat_map { |c| c[:command] }.join(" ")
      expect(command).to include("--net")
      expect(command).not_to match(/--network[ =]host|--net[ =]host|--privileged|--cap-add|--device|--security-opt|--pid[ =]host|--ipc[ =]host|--userns[ =]host|-v\s|--volume|--add-host|--dns/)
      expect(command).not_to match(/docker\.sock|dockerd|nsenter|sudo/)
    end

    it "has no way to name the host socket or metadata endpoint in the command it runs" do
      command = calls.flat_map { |c| c[:command] }.join(" ")
      expect(command).not_to match(/169\.254|metadata|kubernetes|\.svc|localhost|docker\.sock/)
    end
  end
end
