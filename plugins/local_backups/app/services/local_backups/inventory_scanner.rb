module LocalBackups
  class InventoryScanner
    Result = Data.define(:discovered, :invalid)

    def initialize(root: StorageRoot.from_env)
      @root = root
    end

    def call
      discovered = []
      invalid = []
      @root.path.children.sort.each do |entry|
        next unless entry.basename.to_s.start_with?("syrus-backup-v1-")
        next unless entry.directory?

        scan(entry, discovered, invalid)
      end
      Result.new(discovered:, invalid:)
    end

    private

    def scan(entry, discovered, invalid)
      directory = @root.contain!(entry)
      manifest = Manifest.read(directory.join(Manifest::FILE_NAME))
      attributes = attributes_for(manifest, directory)
      uuid = attributes.fetch(:uuid)
      backup = Backup.find_by(uuid:) || create_backup(attributes)
      backup.update!(attributes.except(:uuid))
      discovered << backup
    rescue StorageRoot::Error, Manifest::Error, ActiveRecord::RecordInvalid => e
      invalid << { path: entry.basename.to_s, error: e.message }
    end

    def create_backup(attributes)
      Backup.create!(attributes)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      backup = Backup.find_by(uuid: attributes.fetch(:uuid))
      return backup if backup

      raise
    end

    def attributes_for(manifest, directory)
      data = manifest.data
      {
        uuid: data.fetch("backup_id"), state: "completed", artifact_path: directory.relative_path_from(@root.path).to_s,
        manifest_version: data.fetch("manifest_version"), database_adapter: data.dig("database", "adapter"),
        logical_bytes: data.dig("storage", "logical_bytes").to_i, stored_bytes: data.dig("storage", "stored_bytes").to_i,
        blob_count: data.dig("storage", "blob_count").to_i, checksum_algorithm: data.dig("artifact", "checksum_algorithm"),
        checksum: data.dig("artifact", "checksum"), verification_state: "valid",
        encryption_fingerprints: data.fetch("encryption_fingerprints"), source_application_version: data["application_version"],
        completed_at: data.fetch("completed_at"), validated_at: data.fetch("validated_at")
      }
    end
  end
end
