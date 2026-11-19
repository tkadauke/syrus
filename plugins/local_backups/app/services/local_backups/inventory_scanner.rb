module LocalBackups
  class InventoryScanner
    Result = Data.define(:discovered, :invalid)

    def initialize(root: StorageRoot.new)
      @root = root
    end

    def call
      discovered = 0
      invalid = []
      @root.path.children.select(&:directory?).sort.each do |directory|
        next if directory.basename.to_s.start_with?(".")
        next unless directory.join(Manifest::FILE_NAME).file?

        manifest = Manifest.read(@root.contained(directory.basename).join(Manifest::FILE_NAME))
        upsert!(directory.basename.to_s, manifest.attributes)
        discovered += 1
      rescue Manifest::Invalid, StorageRoot::Invalid => e
        invalid << { path: directory.basename.to_s, error: e.message }
      end
      Result.new(discovered:, invalid:)
    end

    private

    def upsert!(relative_path, payload)
      artifact = payload.fetch("artifact")
      checksum = payload.fetch("checksum")
      Backup.find_or_initialize_by(uuid: payload.fetch("backup_id")).tap do |backup|
        backup.assign_attributes(
          state: "completed", artifact_relative_path: relative_path,
          manifest_version: payload.fetch("manifest_version"), reason: payload["reason"],
          database_adapter: payload.dig("database", "adapter"),
          logical_bytes: artifact.fetch("logical_bytes", 0), stored_bytes: artifact.fetch("stored_bytes", 0),
          blob_count: artifact.fetch("blob_count", 0), completed_at: payload.fetch("completed_at"),
          validated_at: payload["validated_at"], verification_state: payload.dig("validation", "state"),
          source_application_version: payload.dig("source", "application_version"),
          artifact_checksum: checksum.fetch("value"), checksum_algorithm: checksum.fetch("algorithm"),
          encryption_key_fingerprint: payload.dig("encryption", "key_fingerprint")
        )
        backup.save!
      end
    end
  end
end
