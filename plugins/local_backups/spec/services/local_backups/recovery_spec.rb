require "spec_helper"
require "stringio"
require "time"
require_relative "../../../lib/local_backups/recovery"

RSpec.describe LocalBackups::Recovery do
  def build_artifact(root, content: "database", manifest: {})
    artifact = Pathname.new(root).join("bundle").tap(&:mkpath)
    artifact.join("database").mkpath
    artifact.join("database/primary.sqlite3").binwrite(content)
    checksum = Digest::SHA256.hexdigest(content)
    artifact.join("checksums.sha256").write("#{checksum}  database/primary.sqlite3\n")
    artifact_checksum = Digest::SHA256.file(artifact.join("checksums.sha256")).hexdigest
    artifact.join("manifest.json").write(JSON.generate({
      manifest_version: "1.0", backup_id: SecureRandom.uuid, completed_at: Time.now.utc.iso8601,
      checksum: artifact_checksum, database: { adapter: "sqlite3" }
    }.merge(manifest)))
    artifact
  end

  it "validates a bundle without a database inventory row" do
    Dir.mktmpdir do |directory|
      result = described_class::Artifact.new(build_artifact(directory)).validate
      expect(result.logical_bytes).to eq(8)
      expect(result.artifact_checksum).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  it "rejects corrupt bundles" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)
      artifact.join("database/primary.sqlite3").write("corrupt")
      expect { described_class::Artifact.new(artifact).validate }
        .to raise_error(described_class::InvalidArtifact, /checksum mismatch/)
    end
  end

  it "rejects files that are absent from the checksum inventory" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)
      artifact.join("unlisted").write("payload")

      expect { described_class::Artifact.new(artifact).validate }
        .to raise_error(described_class::InvalidArtifact, /unexpected entry: unlisted/)
    end
  end

  it "applies the byte limit to directory artifact metadata" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)

      expect { described_class::Artifact.new(artifact, max_bytes: 7).validate }
        .to raise_error(described_class::LimitExceeded, /artifact exceeds 7 bytes/)
    end
  end

  it "bounds manifest memory before parsing" do
    stub_const("LocalBackups::Recovery::MAX_MANIFEST_BYTES", 10)
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)

      expect { described_class::Artifact.new(artifact).validate }
        .to raise_error(described_class::LimitExceeded, /manifest exceeds 10 bytes/)
    end
  end

  it "bounds checksum inventory line memory" do
    stub_const("LocalBackups::Recovery::MAX_CHECKSUM_LINE_BYTES", 10)
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)

      expect { described_class::Artifact.new(artifact).validate }
        .to raise_error(described_class::LimitExceeded, /checksum inventory line exceeds 10 bytes/)
    end
  end

  it "rejects archive traversal and decompression beyond the limit" do
    Dir.mktmpdir do |directory|
      archive = Pathname.new(directory).join("attack.tar")
      File.open(archive, "wb") do |io|
        Gem::Package::TarWriter.new(io) { |tar| tar.add_file_simple("../escape", 0o600, 1) { |entry| entry.write("x") } }
      end
      expect { described_class::Artifact.new(archive).validate }
        .to raise_error(described_class::InvalidArtifact, /escapes/)

      large = Pathname.new(directory).join("large.tar")
      File.open(large, "wb") do |io|
        Gem::Package::TarWriter.new(io) { |tar| tar.add_file_simple("large", 0o600, 10) { |entry| entry.write("x" * 10) } }
      end
      expect { described_class::Artifact.new(large, max_bytes: 5).validate }
        .to raise_error(described_class::LimitExceeded)
    end
  end

  it "rejects archive entry-count attacks before exhausting filesystem inodes" do
    Dir.mktmpdir do |directory|
      archive = Pathname.new(directory).join("entries.tar")
      File.open(archive, "wb") do |io|
        Gem::Package::TarWriter.new(io) do |tar|
          3.times { |index| tar.add_file_simple("empty-#{index}", 0o600, 0) {} }
        end
      end

      expect { described_class::Artifact.new(archive, max_entries: 2).validate }
        .to raise_error(described_class::LimitExceeded, /more than 2 entries/)
    end
  end

  it "counts implicit parent directories against the archive entry limit" do
    Dir.mktmpdir do |directory|
      archive = Pathname.new(directory).join("deep-entry.tar")
      File.open(archive, "wb") do |io|
        Gem::Package::TarWriter.new(io) do |tar|
          tar.add_file_simple("one/two/three/empty", 0o600, 0) {}
        end
      end

      expect { described_class::Artifact.new(archive, max_entries: 3).validate }
        .to raise_error(described_class::LimitExceeded, /materialize more than 3 filesystem entries/)
    end
  end

  it "applies entry-count limits to directory artifacts" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)

      expect { described_class::Artifact.new(artifact, max_entries: 2).validate }
        .to raise_error(described_class::LimitExceeded, /more than 2 entries/)
    end
  end

  it "rejects excessively deep artifact paths" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)
      artifact.join(*(1..65).map { |index| "level-#{index}" }).mkpath

      expect { described_class::Artifact.new(artifact).validate }
        .to raise_error(described_class::LimitExceeded, /exceeds 64 components/)
    end
  end

  it "reports incompatibility and key mismatch while tolerating an unavailable database" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory, manifest: {
        source_application_version: "2.0.0", encryption_key_fingerprints: { primary: "sha256:expected" },
        plugins: { "durable_plugin" => "1.0" }
      })
      environment = {
        "SYRUS_INSTALLATION_ID" => "installation-a", "SYRUS_VERSION" => "1.0.0",
        "SYRUS_DATABASE_ADAPTER" => "mysql2", "SYRUS_RECOVERY_KEY_PRIMARY" => "sha256:other",
        "SYRUS_RECOVERY_DESTINATION" => directory, "SYRUS_RECOVERY_AVAILABLE_BYTES" => "100000"
      }
      result = described_class::Preflight.new(artifact: described_class::Artifact.new(artifact), environment:).call
      expect(result[:status]).to eq("failed")
      expect(result[:checks]).to include(hash_including(name: "destination_database", status: "warning"))
      expect(result[:checks]).to include(hash_including(name: "encryption_key:primary", status: "failed"))
      expect(result[:checks]).to include(hash_including(name: "plugin:durable_plugin", status: "failed"))
    end
  end

  it "binds stable preflight tokens to the artifact and installation" do
    Dir.mktmpdir do |directory|
      artifact = described_class::Artifact.new(build_artifact(directory))
      base = { "SYRUS_RECOVERY_DESTINATION" => directory, "SYRUS_RECOVERY_AVAILABLE_BYTES" => "100000" }
      first = described_class::Preflight.new(artifact:, environment: base.merge("SYRUS_INSTALLATION_ID" => "a")).call
      repeat = described_class::Preflight.new(artifact:, environment: base.merge("SYRUS_INSTALLATION_ID" => "a")).call
      other = described_class::Preflight.new(artifact:, environment: base.merge("SYRUS_INSTALLATION_ID" => "b")).call
      expect(first[:preflight_token]).to eq(repeat[:preflight_token])
      expect(other[:preflight_token]).not_to eq(first[:preflight_token])
      expect {
        described_class::Preflight.verify_token!(
          provided: first[:preflight_token], checksum: first[:artifact_checksum], identity: "b"
        )
      }.to raise_error(described_class::Error, /stale/)
    end
  end

  it "makes an issued token stale when the manifest changes" do
    Dir.mktmpdir do |directory|
      path = build_artifact(directory)
      artifact = described_class::Artifact.new(path)
      environment = {
        "SYRUS_INSTALLATION_ID" => "a", "SYRUS_RECOVERY_DESTINATION" => directory,
        "SYRUS_RECOVERY_AVAILABLE_BYTES" => "100000"
      }
      original = described_class::Preflight.new(artifact:, environment:).call
      manifest_path = path.join("manifest.json")
      manifest = JSON.parse(manifest_path.read).merge("source_application_version" => "changed")
      manifest_path.write(JSON.generate(manifest))
      changed = artifact.validate

      expect(changed.artifact_checksum).not_to eq(original[:artifact_checksum])
      expect {
        described_class::Preflight.verify_token!(
          provided: original[:preflight_token], checksum: changed.artifact_checksum, identity: "a"
        )
      }.to raise_error(described_class::Error, /stale/)
    end
  end

  it "binds validation to the manifest bytes used for compatibility checks" do
    artifact_class = Class.new(described_class::Artifact) do
      def exact_tree_checksum(observations)
        manifest_path = source.join("manifest.json")
        replacement = JSON.parse(manifest_path.read).merge("source_application_version" => "changed")
        manifest_path.write(JSON.generate(replacement))
        super
      end
    end

    Dir.mktmpdir do |directory|
      path = build_artifact(directory)
      observed = artifact_class.new(path).validate
      current = described_class::Artifact.new(path).validate
      old_token = described_class::Preflight.token_for(observed.artifact_checksum, "a")

      expect(observed.manifest).not_to have_key("source_application_version")
      expect(current.artifact_checksum).not_to eq(observed.artifact_checksum)
      expect {
        described_class::Preflight.verify_token!(
          provided: old_token, checksum: current.artifact_checksum, identity: "a"
        )
      }.to raise_error(described_class::Error, /stale/)
    end
  end

  it "imports mounted artifacts and enforces streamed upload limits" do
    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)
      destination = Pathname.new(directory).join("imports")
      imported = described_class::Importer.new(destination:, max_bytes: 1000).import(artifact)
      expect(Pathname.new(imported[:imported_to])).to be_directory
      expect { described_class::Importer.new(destination:, max_bytes: 3).receive(StringIO.new("four")) }
        .to raise_error(described_class::LimitExceeded)
      expect(destination.children.select { |path| path.basename.to_s.end_with?(".partial") }).to be_empty
    end
  end

  it "rejects a mounted artifact that changes while it is imported" do
    importer_class = Class.new(described_class::Importer) do
      def copy_bounded(source, target)
        source.join("database/primary.sqlite3").write("changed after validation")
        super
      end
    end

    Dir.mktmpdir do |directory|
      artifact = build_artifact(directory)
      destination = Pathname.new(directory).join("imports")

      expect { importer_class.new(destination:, max_bytes: 1000).import(artifact) }
        .to raise_error(described_class::InvalidArtifact, /checksum mismatch/)
      expect(destination.children).to be_empty
    end
  end
end
