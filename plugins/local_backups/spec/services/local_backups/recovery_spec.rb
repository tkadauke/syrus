require "rails_helper"
require "rbconfig"
require "shellwords"
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

  describe LocalBackups::Recovery::Restore do
    def create_restore_bundle(root)
      bundle = Pathname.new(root).join("restore-bundle").tap(&:mkpath)
      database_dir = bundle.join("database").tap(&:mkpath)
      database = SQLite3::Database.new(database_dir.join("primary.sqlite3").to_s)
      database.execute("CREATE TABLE recovery_probe (value TEXT NOT NULL)")
      database.execute("INSERT INTO recovery_probe VALUES ('restored')")
      database.close
      blob = bundle.join("blobs/ab/cd/abcdef").tap { |path| path.dirname.mkpath }
      blob.binwrite("restored object")
      validation = bundle.join("validation.json").tap { |path| path.write("{}\n") }
      checksums = bundle.join("checksums.sha256")
      checked = [database_dir.join("primary.sqlite3"), blob, validation]
      checksums.write(checked.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path.relative_path_from(bundle)}\n" }.join)
      manifest = {
        manifest_version: "1.0", backup_id: "restore-1", completed_at: "2026-11-20T00:00:00Z",
        artifact: { format: "directory", checksum_path: "checksums.sha256" },
        checksum: Digest::SHA256.file(checksums).hexdigest,
        database: { adapter: "sqlite3", path: "database/primary.sqlite3" },
        active_storage: { service: "Disk", blob_count: 1, blobs: [{ id: 1, relative_path: "blobs/ab/cd/abcdef",
          bundle_checksum: Digest::SHA256.file(blob).hexdigest }] }
      }
      bundle.join("manifest.json").write(JSON.generate(manifest))
      bundle
    end

    def safety_command(source)
      ruby = RbConfig.ruby
      script = <<~'RUBY'
        require "fileutils"
        source, destination = ARGV
        FileUtils.copy_entry(source, destination, false, false, true)
      RUBY
      [ruby, "-e", script, source.to_s].map { |part| Shellwords.escape(part) }.join(" ") + ' "$SYRUS_PRE_RESTORE_BACKUP_PATH"'
    end

    def restore_options(root, bundle, phase_hook: ->(_phase) { })
      data = Pathname.new(root).join("data").tap(&:mkpath)
      database = data.join("primary.sqlite3")
      SQLite3::Database.new(database.to_s).tap { |db| db.execute("CREATE TABLE old_state (value TEXT)"); db.close }
      objects = data.join("storage").tap(&:mkpath)
      objects.join("old").write("old object")
      safety_root = Pathname.new(root).join("safety").tap(&:mkpath)
      marker = Pathname.new(root).join("maintenance/active")
      recovery_bundle = LocalBackups::Recovery::Bundle.new(bundle)
      token = LocalBackups::Recovery::Token.issue(secret: "secret", artifact_checksum: recovery_bundle.identity_checksum, installation_id: "installation")
      commands = { enter: "true", drain: "true", verify_drained: "true", safety_backup: safety_command(bundle),
        rebuild: "true", reconcile: "true", health_check: "true", resume: "true" }
      [{ bundle: recovery_bundle, token:, token_secret: "secret", installation_id: "installation", destination: data,
        database_destination: database, objects_destination: objects, safety_root:, maintenance_marker: marker,
        commands:, phase_hook: }, database, objects, marker, safety_root]
    end

    it "stages, validates, promotes, verifies, and resumes a SQLite/Disk restore" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        options, database, objects, marker, safety_root = restore_options(root, create_restore_bundle(root))

        result = described_class.new(**options).call

        restored = SQLite3::Database.new(database.to_s, readonly: true)
        expect(restored.get_first_value("SELECT value FROM recovery_probe")).to eq("restored")
        restored.close
        expect(objects.join("ab/cd/abcdef").read).to eq("restored object")
        expect(marker).not_to exist
        expect(result.status).to eq("restored")
        expect(Pathname.new(result.safety_backup).join("PINNED")).to exist
        expect(Pathname.new(result.safety_backup).to_s).to start_with(safety_root.to_s)
      end
    end

    it "fails before promotion when staged objects are corrupt and leaves maintenance active" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        bundle = create_restore_bundle(root)
        manifest = JSON.parse(bundle.join("manifest.json").read)
        manifest["active_storage"]["blobs"][0]["bundle_checksum"] = "0" * 64
        bundle.join("manifest.json").write(JSON.generate(manifest))
        options, database, _objects, marker, = restore_options(root, bundle)

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /staged object checksum/)
        expect(SQLite3::Database.new(database.to_s, readonly: true).table_info("old_state")).not_to be_empty
        expect(marker).to exist
      end
    end

    it "keeps maintenance active and reports rollback after a failure during promotion" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        hook = ->(phase) { raise "promotion interrupted" if phase == :database_promoted }
        options, database, _objects, marker, = restore_options(root, create_restore_bundle(root), phase_hook: hook)
        output = StringIO.new
        options[:output] = output

        expect { described_class.new(**options).call }.to raise_error("promotion interrupted")
        expect(SQLite3::Database.new(database.to_s, readonly: true).get_first_value("SELECT value FROM recovery_probe")).to eq("restored")
        expect(marker).to exist
        failure = JSON.parse(output.string.lines.last)
        expect(failure).to include("maintenance_mode" => true)
        expect(failure.fetch("rollback").join).to include("replace")
        expect(failure.fetch("rollback").last).to include("remove maintenance marker #{marker}")
      end
    end

    it "requires an explicit break-glass confirmation when no safety backup can be made" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        options, = restore_options(root, create_restore_bundle(root))
        options[:commands] = options[:commands].merge(safety_backup: nil)

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /break-glass/)
        expect(Pathname.new(options[:maintenance_marker])).to exist
      end
    end

    it "restores with explicit break-glass confirmation when no safety backup can be made" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        options, database, _objects, marker, = restore_options(root, create_restore_bundle(root))
        options[:commands] = options[:commands].merge(safety_backup: nil)
        options[:break_glass] = true

        result = described_class.new(**options).call

        restored = SQLite3::Database.new(database.to_s, readonly: true)
        expect(restored.get_first_value("SELECT value FROM recovery_probe")).to eq("restored")
        restored.close
        expect(result.safety_backup).to be_nil
        expect(marker).not_to exist
      end
    end

    it "reports that maintenance is inactive when preflight validation fails" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        options, = restore_options(root, create_restore_bundle(root))
        options[:token] = "invalid"
        output = StringIO.new
        options[:output] = output

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /preflight token/)
        failure = JSON.parse(output.string.lines.last)
        expect(failure).to include("maintenance_mode" => false, "rollback" => [])
        expect(Pathname.new(options[:maintenance_marker])).not_to exist
      end
    end

    it "rejects object paths outside the bundle blobs directory" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        bundle = create_restore_bundle(root)
        blob = bundle.join("config/evil").tap { |path| path.dirname.mkpath }
        blob.write("escaped object")
        manifest = JSON.parse(bundle.join("manifest.json").read)
        manifest["active_storage"]["blobs"] = [{ "id" => 1, "relative_path" => "config/evil",
          "bundle_checksum" => Digest::SHA256.file(blob).hexdigest }]
        checksums = bundle.join("checksums.sha256")
        checksums.write(checksums.read + "#{Digest::SHA256.file(blob).hexdigest}  config/evil\n")
        manifest["checksum"] = Digest::SHA256.file(checksums).hexdigest
        bundle.join("manifest.json").write(JSON.generate(manifest))
        options, = restore_options(root, bundle)

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /beneath blobs/)
        expect(Pathname.new(options[:destination]).join("config/evil")).not_to exist
      end
    end

    it "refuses restore when mutating processes remain and preserves the maintenance marker" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        options, = restore_options(root, create_restore_bundle(root))
        options[:commands] = options[:commands].merge(verify_drained: "false")

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /verification failed/)
        expect(Pathname.new(options[:maintenance_marker])).to exist
      end
    end

    it "coordinates isolated MySQL and S3-compatible staging and records external rollback" do
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        bundle = create_bundle(root, manifest: {
          database: { adapter: "mysql2", path: "database.sqlite3" },
          active_storage: { service: "S3", blob_count: 0, blobs: [] }
        })
        options, = restore_options(root, bundle)
        log = root.join("external-phases")
        append = ->(phase) { "printf '%s\\n' #{Shellwords.escape(phase)} >> #{Shellwords.escape(log.to_s)}" }
        options[:commands] = options[:commands].merge(
          mysql_stage_command: append.call("mysql-stage"), mysql_promote_command: append.call("mysql-promote"),
          mysql_rollback_command: "mysql-rollback", object_stage_command: append.call("object-stage"),
          object_promote_command: append.call("object-promote"), object_rollback_command: "object-rollback",
          health_check: "false"
        )
        output = StringIO.new
        options[:output] = output

        expect { described_class.new(**options).call }.to raise_error(LocalBackups::Recovery::Error, /health check failed/)
        expect(log.readlines(chomp: true)).to eq(%w[mysql-stage object-stage mysql-promote object-promote])
        rollback = JSON.parse(output.string.lines.last).fetch("rollback")
        expect(rollback).to eq(["run: object-rollback", "run: mysql-rollback",
          "after rollback succeeds, remove maintenance marker #{options[:maintenance_marker]} before resuming service"])
        expect(Pathname.new(options[:maintenance_marker])).to exist
      end
    end
  end
end
