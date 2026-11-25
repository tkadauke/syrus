require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::CoworkerBase do
  let(:dockerfile) { described_class::DIRECTORY.join("Dockerfile").read }

  it "ships a sound definition" do
    expect(described_class.validate).to eq([])
  end

  it "installs every bundled provider CLI and probes each one" do
    expect(described_class.provider_keys).to match_array(%w[claude codex agy muse])
    probe = described_class::DIRECTORY.join("syrus-base-probe").read
    described_class.provider_keys.each { |key| expect(probe).to include(key) }
    expect(dockerfile).to include("@anthropic-ai/claude-code@", "@openai/codex@", "/usr/local/bin/agy", "/opt/muse/bin/muse")
  end

  it "covers every agent provider plugin that bundles a CLI" do
    providers = Dir[Rails.root.join("plugins/*_agent/app/services/agent_providers/*.rb")].map { |f| File.basename(f, ".rb") }
    expect(providers - described_class.provider_keys).to be_empty
  end

  it "runs as the configured non-root identity" do
    expect(described_class.user).to include("name" => "coworker", "uid" => 1000, "gid" => 1000)
    expect(dockerfile).to match(/^USER \$\{COWORKER_UID\}:\$\{COWORKER_GID\}$/)
  end

  it "needs no write access outside its declared mounts" do
    expect(described_class.writable_paths).to eq(%w[/workspace /home/coworker /tmp])
    expect(described_class::DIRECTORY.join("syrus-base-probe").read).to include("read-only-root")
  end

  it "pins every downloaded artifact by checksum" do
    expect(dockerfile.scan("sha512sum -c").size).to eq(1)
    expect(dockerfile.scan("sha256sum -c").size).to eq(2)
    expect(dockerfile).to include("NODESOURCE_GPG_FINGERPRINT")
  end

  describe "credential hygiene" do
    it "rejects credential-named build inputs, secret mounts, and auth files" do
      bad = [ "ARG GITHUB_TOKEN\n", "ENV ANTHROPIC_API_KEY=x\n", "RUN --mount=type=secret,id=x true\n", "RUN echo a > ~/.npmrc\n", "RUN docker login r\n" ]
      bad.each do |line|
        problems = described_class.send(:credential_problems, "FROM scratch\n#{line}")
        expect(problems).not_to be_empty, "expected #{line.inspect} to be rejected"
      end
    end

    it "accepts the real Dockerfile" do
      expect(described_class.send(:credential_problems, dockerfile)).to eq([])
    end
  end

  describe ".validate" do
    it "flags a base image that is not pinned by digest" do
      allow(described_class).to receive(:base_image).and_return("docker.io/library/debian:bookworm-slim")
      expect(described_class.validate).to include("base_image is not pinned by digest")
    end

    it "flags a root identity" do
      allow(described_class).to receive(:user).and_return({ "uid" => 0, "gid" => 0 })
      expect(described_class.validate).to include("user must be non-root")
    end

    it "raises from validate! when unsound" do
      allow(described_class).to receive(:base_image).and_return("debian:latest")
      expect { described_class.validate! }.to raise_error(described_class::InvalidDefinition, /pinned by digest/)
    end
  end

  describe "source archive" do
    it "is byte-for-byte reproducible and content addressed" do
      first = described_class.source_archive
      expect(described_class.source_archive).to eq(first)
      expect(described_class.source_digest(first)).to eq("sha256:#{Digest::SHA256.hexdigest(first)}")
    end

    it "contains the build definition with the probe executable" do
      names = {}
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(described_class.source_archive))) do |tar|
        tar.each { |entry| names[entry.full_name] = entry.header.mode }
      end
      expect(names.keys).to match_array(%w[Dockerfile base.yml syrus-base-probe])
      expect(names["syrus-base-probe"]).to eq(0o755)
    end

    it "is accepted as an immutable source capture" do
      capture = described_class.source_capture
      expect(capture.manifest["revision"]).to eq(described_class.source_digest)
      expect(capture.manifest["kind"]).to eq("syrus_base")
    end

    it "fits the build plane's source ceiling" do
      expect(described_class.source_archive.bytesize).to be < RuntimeImages::Builds::Config.max_source_bytes
    end
  end

  describe ".recipe" do
    it "uses only keys the isolated builder accepts, with the pinned base" do
      expect(RuntimeImages::Builds::IsolatedBuilder::ALLOWED_RECIPE_KEYS).to include(*described_class.recipe.keys)
      expect(described_class.recipe.dig("build_args", "BASE_IMAGE")).to match(described_class::DIGEST_PINNED)
    end
  end

  describe ".submit" do
    let(:provider) { SyntheticRuntimeImageProvider.new }
    let(:built_images) { RuntimeImages::BuiltImages.new(engine: double("engine"), provider_key: provider.key) }

    it "queues a build of the archived definition in the base namespace and deduplicates" do
      request = described_class.submit(built_images: built_images)

      expect(request).to be_queued
      expect(request.source_digest).to eq(described_class.source_capture.digest)
      expect(request.recipe).to eq(described_class.recipe)
      expect(request.platform).to eq("linux/amd64")
      expect(request.source_archive).to be_attached
      expect(request.source_archive.blob.checksum).to be_present
      expect(request.runtime_image_namespace.owner_kind).to eq("syrus_base")

      expect(described_class.submit(built_images: built_images).id).to eq(request.id)
    end

    it "builds each platform separately" do
      amd = described_class.submit(built_images: built_images)
      arm = described_class.submit(platform: "linux/arm64", built_images: built_images)
      expect(arm.id).not_to eq(amd.id)
    end

    it "refuses unsupported platforms and unsound definitions" do
      expect { described_class.submit(platform: "linux/s390x", built_images: built_images) }.to raise_error(described_class::InvalidDefinition)
      allow(described_class).to receive(:validate).and_return([ "broken" ])
      expect { described_class.submit(built_images: built_images) }.to raise_error(described_class::InvalidDefinition, /broken/)
    end
  end

  describe ".current_image" do
    let(:provider) { SyntheticRuntimeImageProvider.new }
    let(:built_images) { RuntimeImages::BuiltImages.new(engine: double("engine"), provider_key: provider.key) }

    it "is nil until published, then the pullable image by digest" do
      expect(described_class.current_image(built_images: built_images)).to be_nil

      namespace = built_images.namespace_for("syrus_base", "coworker-base")
      image = RuntimeImages::Service.new(provider: provider).publish(
        namespace: namespace, source_kind: "syrus_base", source_ref: described_class.source_ref,
        source_digest: described_class.source_digest, platform: "linux/amd64", payload: "base"
      )
      expect(described_class.current_image(built_images: built_images)).to eq(image)
      expect(image.digest).to match(RuntimeImage::DIGEST_FORMAT)
    end
  end

  describe ".probe_command" do
    let(:digest) { "docker.io/syrus/base@sha256:#{"a" * 64}" }

    it "runs the probe read-only, non-root, capability-free, and offline" do
      argv = described_class.probe_command(digest)
      expect(argv).to include("--read-only", "--cap-drop", "ALL", "no-new-privileges", "none", "1000:1000", "/usr/local/bin/syrus-base-probe")
      expect(argv.last).to eq(digest)
    end

    it "refuses tag references" do
      expect { described_class.probe_command("syrus/base:latest") }.to raise_error(described_class::InvalidDefinition)
    end
  end
end
