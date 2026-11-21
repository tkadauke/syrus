require "rails_helper"
require Rails.root.join("plugins/local_backups/lib/local_backups/recovery")

RSpec.describe LocalBackups::Recovery do
  def create_bundle(root, manifest: {})
    bundle = Pathname.new(root).join("bundle").tap(&:mkpath)
    database = bundle.join("database.sqlite3")
    database.binwrite("database")
    checksums = bundle.join("checksums.sha256")
    checksums.write("#{Digest::SHA256.file(database).hexdigest}  database.sqlite3\n")
    payload = {
      manifest_version: "1.0", backup_id: "backup-1", completed_at: "2026-11-20T00:00:00Z",
      artifact: { format: "directory", checksum_path: "checksums.sha256" },
      checksum: Digest::SHA256.file(checksums).hexdigest,
      database: { adapter: "sqlite3" }
    }.deep_merge(manifest)
    bundle.join("manifest.json").write(JSON.generate(payload))
    bundle
  end

  def create_restore_bundle(root)
    bundle = Pathname.new(root).join("restore-bundle").tap(&:mkpath)
    database = bundle.join("database/primary.sqlite3")
    database.dirname.mkpath
    sqlite = SQLite3::Database.new(database.to_s)
    sqlite.execute("CREATE TABLE active_storage_blobs (id INTEGER PRIMARY KEY, key TEXT)")
    key = "abcd-restored-key"
    sqlite.execute("INSERT INTO active_storage_blobs (key) VALUES (?)", key)
    sqlite.close
    blob = bundle.join("blobs/ab/cd/#{key}")
    blob.dirname.mkpath
    blob.binwrite("restored object")
    validation = bundle.join("validation.json").tap { |path| path.write("{}") }
    checksums = bundle.join("checksums.sha256")
    files = [database, blob, validation]
    checksums.write(files.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path.relative_path_from(bundle)}\n" }.join)
    manifest = {
      manifest_version: "1.0", backup_id: "restore-1", completed_at: "2026-11-20T00:00:00Z",
      artifact: { format: "directory", checksum_path: "checksums.sha256" }, checksum: Digest::SHA256.file(checksums).hexdigest,
      database: { adapter: "sqlite3", path: "database/primary.sqlite3", schema_version: 0 },
      active_storage: { service: "Disk", blob_count: 1, blobs: [{ key:, relative_path: "blobs/ab/cd/#{key}",
        byte_size: blob.size, bundle_checksum: Digest::SHA256.file(blob).hexdigest }] }
    }
    bundle.join("manifest.json").write(JSON.generate(manifest))
    bundle
  end

  it "validates a bundle without Rails or an inventory record" do
    Dir.mktmpdir do |directory|
      bundle = described_class::Bundle.new(create_bundle(directory)).validate!
      expect(bundle.manifest).to include("backup_id" => "backup-1")
    end
  end

  it "rejects corrupt contents and checksum paths that escape the bundle" do
    Dir.mktmpdir do |directory|
      path = create_bundle(directory)
      path.join("database.sqlite3").write("corrupt")
      expect { described_class::Bundle.new(path).validate! }.to raise_error(described_class::Error, /checksum mismatch/)

      path.join("checksums.sha256").write("#{'a' * 64}  ../secret\n")
      payload = JSON.parse(path.join("manifest.json").read)
      payload["checksum"] = Digest::SHA256.file(path.join("checksums.sha256")).hexdigest
      path.join("manifest.json").write(JSON.generate(payload))
      expect { described_class::Bundle.new(path).validate! }.to raise_error(described_class::Error, /escapes/)
    end
  end

  it "rejects archive traversal, links, and expanded size attacks" do
    archive = StringIO.new
    Gem::Package::TarWriter.new(archive) { |tar| tar.add_file_simple("../escape", 0o600, 1) { |file| file.write("x") } }
    archive.rewind
    expect { described_class::Bundle.materialize(archive) }.to raise_error(described_class::Error, /escapes/)

    archive = StringIO.new
    Gem::Package::TarWriter.new(archive) { |tar| tar.add_file_simple("large", 0o600, 2) { |file| file.write("xx") } }
    archive.rewind
    expect { described_class::Bundle.materialize(archive, max_bytes: 1) }.to raise_error(described_class::Error, /size limit/)
  end

  it "blocks key, database, and plugin incompatibilities" do
    Dir.mktmpdir do |directory|
      path = create_bundle(directory, manifest: {
        encryption: { key_fingerprints: { primary: "sha256:expected" } },
        plugins: [{ name: "durable_plugin", required: true }],
        restore_compatibility: { application_versions: ["2.0.0"] }
      })
      report = described_class::Preflight.new(
        bundle: described_class::Bundle.new(path), destination: directory, installation_id: "install-a", token_secret: "secret",
        current: { database_adapter: "mysql2", application_version: "1.0.0", plugins: [], encryption_fingerprints: { primary: "sha256:other" } }
      ).call
      expect(report[:status]).to eq("blocked")
      expect(report[:checks].select { |check| check[:status] == "fail" }.map { |check| check[:name] })
        .to contain_exactly("database", "application", "plugins", "encryption")
      expect(report[:token]).to be_nil
    end
  end

  it "accepts a name-only declaration for an available plugin" do
    Dir.mktmpdir do |directory|
      path = create_bundle(directory, manifest: { plugins: [{ name: "durable_plugin", required: true }] })
      report = described_class::Preflight.new(
        bundle: described_class::Bundle.new(path), destination: directory, installation_id: "install-a", token_secret: "secret",
        current: { database_adapter: "sqlite3", plugins: ["durable_plugin"] }
      ).call

      expect(report[:checks]).to include(include(name: "plugins", status: "pass"))
    end
  end

  it "blocks a versioned plugin requirement when the destination version is unknown" do
    Dir.mktmpdir do |directory|
      path = create_bundle(directory, manifest: { plugins: [{ name: "durable_plugin", version: "2.0", required: true }] })
      report = described_class::Preflight.new(
        bundle: described_class::Bundle.new(path), destination: directory, installation_id: "install-a", token_secret: "secret",
        current: { database_adapter: "sqlite3", plugins: ["durable_plugin"] }
      ).call

      expect(report).to include(status: "blocked", token: nil)
      expect(report[:checks]).to include(include(
        name: "plugins", status: "fail", detail: /durable_plugin \(bundle 2.0, destination unknown\)/
      ))
    end
  end

  it "issues stable tokens bound to the artifact and installation and explains unknown live work" do
    Dir.mktmpdir do |directory|
      bundle = described_class::Bundle.new(create_bundle(directory))
      build = lambda do |installation|
        described_class::Preflight.new(
          bundle:, destination: directory, installation_id: installation, token_secret: "secret",
          current: { database_adapter: "sqlite3", plugins: [] }
        ).call
      end
      first = build.call("install-a")
      expect(build.call("install-a")[:token]).to eq(first[:token])
      expect(build.call("install-b")[:token]).not_to eq(first[:token])
      expect(described_class::Token.valid?(
        first[:token], secret: "secret", artifact_checksum: first[:artifact_checksum], installation_id: "install-a"
      )).to be(true)
      expect(described_class::Token.valid?(
        first[:token], secret: "secret", artifact_checksum: first[:artifact_checksum], installation_id: "install-b"
      )).to be(false)
      expect(first[:checks]).to include(include(name: "in_flight_work", status: "warn", detail: /database unavailable/))
      expect(first[:expected_rebuilds]).to include("chat_search", "workflow_workspaces")
    end
  end

  it "imports a validated mounted bundle without an inventory database" do
    Dir.mktmpdir do |directory|
      source = Pathname.new(directory).join("source").tap(&:mkpath)
      destination = Pathname.new(directory).join("destination").tap(&:mkpath)
      bundle = described_class::Bundle.new(create_bundle(source))
      imported = described_class::Importer.new(root: destination).import(bundle)
      expect(described_class::Bundle.new(imported).validate!.manifest["backup_id"]).to eq("backup-1")
    end
  end

  it "rejects a backup ID that could escape the import root" do
    Dir.mktmpdir do |directory|
      source = Pathname.new(directory).join("source").tap(&:mkpath)
      destination = Pathname.new(directory).join("destination").tap(&:mkpath)
      bundle = described_class::Bundle.new(create_bundle(source, manifest: { backup_id: "nested/../../outside" }))

      expect { described_class::Importer.new(root: destination).import(bundle) }
        .to raise_error(described_class::Error, "backup_id is not a safe filename")
      expect(Pathname.new(directory).join("outside")).not_to exist
    end
  end

  it "restores SQLite and Disk state through staging and keeps a pinned safety copy" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      destination = root.join("data").tap(&:mkpath)
      database = destination.join("primary.sqlite3").tap { |path| path.write("old database") }
      storage = destination.join("storage").tap(&:mkpath)
      storage.join("old").write("old object")
      pid_file = root.join("worker.pid").tap { |path| path.write("99999999") }
      bundle = described_class::Bundle.new(create_restore_bundle(root))
      token = described_class::Token.issue(secret: "secret", artifact_checksum: bundle.identity_checksum, installation_id: "install-a")

      result = described_class::Restore.new(bundle:, destination:, database_path: database, storage_path: storage,
        installation_id: "install-a", token_secret: "secret", token:, pid_files: [pid_file]).call

      expect(database.binread).to start_with("SQLite format 3\0")
      expect(storage.join("ab/cd/abcd-restored-key").read).to eq("restored object")
      expect(Pathname.new(result.rollback_path).join("database.sqlite3").read).to eq("old database")
      expect(Pathname.new(result.rollback_path).join("PINNED")).to exist
      expect(destination.join("MAINTENANCE")).not_to exist
    end
  end

  it "refuses restore while a declared mutating process is still alive" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      destination = root.join("data").tap(&:mkpath)
      pid_file = root.join("worker.pid").tap { |path| path.write(Process.pid.to_s) }
      bundle = described_class::Bundle.new(create_restore_bundle(root))
      token = described_class::Token.issue(secret: "secret", artifact_checksum: bundle.identity_checksum, installation_id: "install-a")

      expect { described_class::Restore.new(bundle:, destination:, database_path: destination.join("primary.sqlite3"),
        storage_path: destination.join("storage"), installation_id: "install-a", token_secret: "secret", token:,
        pid_files: [pid_file]).call }.to raise_error(described_class::Error, /still running/)
      expect(destination.join("MAINTENANCE")).to exist
      expect(destination.join("RESTORE_FAILED.json").read).to include("maintenance_required")
    end
  end

  it "leaves maintenance active with rollback instructions when restored-state health fails" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      destination = root.join("data").tap(&:mkpath)
      database = destination.join("primary.sqlite3").tap { |path| path.write("old database") }
      storage = destination.join("storage").tap(&:mkpath)
      pid_file = root.join("worker.pid").tap { |path| path.write("99999999") }
      bundle = described_class::Bundle.new(create_restore_bundle(root))
      token = described_class::Token.issue(secret: "secret", artifact_checksum: bundle.identity_checksum, installation_id: "install-a")

      expect { described_class::Restore.new(bundle:, destination:, database_path: database, storage_path: storage,
        installation_id: "install-a", token_secret: "secret", token:, pid_files: [pid_file],
        health_check: ->(*) { false }).call }.to raise_error(described_class::Error, /health check failed/)
      expect(destination.join("MAINTENANCE")).to exist
      expect(destination.join("RESTORE_FAILED.json").read).to include("pinned pre-restore directory")
      expect(destination.children.map(&:to_s).grep(/pre-restore-.*\.pinned/)).not_to be_empty
    end
  end

  it "fails closed for unqualified database and object-storage topologies" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      path = create_restore_bundle(root)
      manifest = JSON.parse(path.join("manifest.json").read)
      manifest["database"]["adapter"] = "mysql2"
      path.join("manifest.json").write(JSON.generate(manifest))
      bundle = described_class::Bundle.new(path)
      token = described_class::Token.issue(secret: "secret", artifact_checksum: bundle.identity_checksum, installation_id: "install-a")

      expect { described_class::Restore.new(bundle:, destination: root, database_path: root.join("db"), storage_path: root.join("storage"),
        installation_id: "install-a", token_secret: "secret", token:, pid_files: [root.join("worker.pid")]).call }
        .to raise_error(described_class::Error, /not qualified for database adapter/)
    end
  end
end
