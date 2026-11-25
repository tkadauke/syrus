require "digest"
require "securerandom"
require "sqlite3"

module LocalBackups
  class Creator
    class UnsupportedDatabase < StandardError; end

    def initialize(root: StorageRoot.new, snapshotter: DatabaseSnapshot.for, exporter: DiskBlobExporter.new,
      capacity: nil, clock: -> { Time.current }, phase_hook: ->(_phase) { })
      @root = root
      @snapshotter = snapshotter
      @exporter = exporter
      @capacity = capacity || CapacityAdmission.new(root:)
      @clock = clock
      @phase_hook = phase_hook
    end

    def call(reason: "manual")
      Lease.new(root: @root).synchronize { create_under_lease(reason:) }
    end

    private

    def create_under_lease(reason:)
      estimate_and_admit!
      uuid = SecureRandom.uuid
      partial_name = ".backup-#{uuid}.partial"
      partial = @root.path.join(partial_name)
      backup = Backup.create!(
        uuid:, state: "snapshotting", reason:, artifact_relative_path: partial_name,
        manifest_version: Manifest::VERSION, database_adapter: @snapshotter.adapter, started_at: @clock.call
      )
      partial.mkdir(0o700)
      @phase_hook.call(:partial_created)

      database_dir = partial.join("database").tap(&:mkpath)
      snapshot = @snapshotter.create(database_dir.join(@snapshotter.destination_filename))
      @phase_hook.call(:database_snapshotted)
      selection = @snapshotter.select_blobs(snapshot)
      ObjectHold.insert_all!(selection.map { |blob| hold_attributes(backup, blob) }) if selection.any?
      backup.update!(state: "exporting_objects")
      @phase_hook.call(:objects_held)

      entries = @exporter.export(selection, partial)
      backup.update!(state: "validating")
      @phase_hook.call(:objects_exported)
      validation_path = write_validation(partial, snapshot:, entries:)
      readme_path = write_readme(partial)
      checksum_path = write_checksums(partial, snapshot:, entries:, validation_path:, readme_path:)
      artifact_checksum = Digest::SHA256.file(checksum_path).hexdigest
      completed_at = @clock.call
      Manifest.write(partial, manifest_attributes(
        backup:, snapshot:, entries:, artifact_checksum:, completed_at:
      ))
      fsync_file(validation_path)
      fsync_tree(partial)
      @phase_hook.call(:ready_to_seal)

      sealed_name = "syrus-backup-v1-#{completed_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{uuid}"
      sealed = @root.path.join(sealed_name)
      File.rename(partial, sealed)
      fsync_directory(@root.path)
      make_immutable(sealed)
      stored_bytes = tree_bytes(sealed)
      backup.update!(
        state: "completed", artifact_relative_path: sealed_name, logical_bytes: snapshot.bytes + entries.sum(&:byte_size),
        stored_bytes:, blob_count: entries.length, completed_at:, validated_at: completed_at,
        verification_state: "valid", artifact_checksum:
      )
      backup
    rescue StandardError => e
      backup&.update_columns(state: "failed", failed_at: @clock.call, error_class: e.class.name, error_summary: e.message.to_s.first(1000))
      raise
    ensure
      backup&.object_holds&.delete_all
    end

    def estimate_and_admit!
      database_bytes = @snapshotter.estimate_bytes
      blob_bytes = ActiveStorage::Blob.sum(:byte_size)
      @capacity.admit!(database_bytes:, blob_bytes:)
    rescue CapacityAdmission::InsufficientSpace => error
      Retention.new(root: @root).reclaim!(bytes: error.required_bytes - error.available_bytes)
      @capacity.admit!(database_bytes:, blob_bytes:)
    end

    def hold_attributes(backup, blob)
      now = @clock.call
      { backup_id: backup.id, active_storage_blob_id: blob.fetch("id"), storage_key: blob.fetch("key"), created_at: now, updated_at: now }
    end

    def write_checksums(partial, snapshot:, entries:, validation_path:, readme_path:)
      path = partial.join("checksums.sha256")
      database_relative_path = snapshot.path.relative_path_from(partial).to_s
      lines = [[Digest::SHA256.file(snapshot.path).hexdigest, database_relative_path]] +
        entries.map { |entry| [entry.bundle_checksum, entry.relative_path] } +
        [[Digest::SHA256.file(validation_path).hexdigest, "validation.json"],
         [Digest::SHA256.file(readme_path).hexdigest, "README.txt"]]
      write_exclusive(path, lines.map { |checksum, relative| "#{checksum}  #{relative}\n" }.join)
    end

    def write_validation(partial, snapshot:, entries:)
      write_exclusive(partial.join("validation.json"), JSON.pretty_generate(
        result: "valid", database_integrity: snapshot.integrity, checked_blobs: entries.length,
        checksum_algorithm: "sha256"
      ) + "\n")
    end

    def write_readme(partial)
      write_exclusive(partial.join("README.txt"), <<~TEXT)
        Syrus portable recovery bundle, manifest version #{Manifest::VERSION}.
        Validate checksums.sha256 before attempting recovery. Restore support is
        version-sensitive; use the Syrus disaster-recovery tooling that matches
        the compatibility information in manifest.json.
      TEXT
    end

    def write_exclusive(path, content)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      path
    end

    def manifest_attributes(backup:, snapshot:, entries:, artifact_checksum:, completed_at:)
      {
        backup_id: backup.uuid, started_at: backup.started_at.iso8601(6), snapshot_at: snapshot.path.mtime.utc.iso8601(6),
        completed_at: completed_at.iso8601(6), validated_at: completed_at.iso8601(6), reason: backup.reason,
        source_application_version: Syrus::Host::SyrusVersion.description, source_revision: Syrus::Host::SyrusVersion.current,
        artifact: { format: "directory", checksum_path: "checksums.sha256" }, checksum: artifact_checksum,
        database: @snapshotter.manifest(snapshot),
        encryption: { key_fingerprints: encryption_key_fingerprints },
        active_storage: { service: ActiveStorage::Blob.service.class.name.demodulize.delete_suffix("Service"), blob_count: entries.length, logical_bytes: entries.sum(&:byte_size),
          blobs: entries.map(&:to_h) }, validation: { result: "valid", path: "validation.json" }
      }
    end

    def encryption_key_fingerprints
      configuration = Rails.configuration.active_record.encryption
      {
        primary: fingerprint_values(configuration.primary_key),
        deterministic: fingerprint_values(configuration.deterministic_key),
        derivation_salt: fingerprint_values(configuration.key_derivation_salt)
      }.compact
    end

    def fingerprint_values(value)
      fingerprints = Array(value).filter_map { |item| EncryptionFingerprint.for(item) }
      fingerprints.one? ? fingerprints.first : fingerprints.presence
    end

    def fsync_tree(root)
      root.find { |path| fsync_file(path) if path.file? }
      root.find { |path| fsync_directory(path) if path.directory? }
    end

    def fsync_file(path)
      File.open(path, "rb", &:fsync)
    end

    def fsync_directory(path)
      File.open(path, "rb", &:fsync)
    end

    def make_immutable(root)
      root.find { |path| File.chmod(path.directory? ? 0o500 : 0o400, path) }
    end

    def tree_bytes(root)
      root.find.sum { |path| path.file? ? path.size : 0 }
    end
  end
end
