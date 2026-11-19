module LocalBackups
  class ArtifactSource
    include Syrus::Plugin::BackupArtifactSource

    class UnsupportedOperation < StandardError; end

    def self.list(context:)
      Backup.where(state: "completed").order(completed_at: :desc).map { |backup| describe(backup.uuid, context:) }
    end

    def self.describe(backup_id, context:)
      backup = Backup.find_by!(uuid: backup_id)
      {
        id: backup.uuid, completed_at: backup.completed_at, checksum: checksum(backup_id, context:),
        logical_bytes: backup.logical_bytes, stored_bytes: backup.stored_bytes
      }
    end

    def self.open(*)
      raise UnsupportedOperation, "artifact streaming is not available until sealed archives are created"
    end

    def self.checksum(backup_id, context:)
      backup = Backup.find_by!(uuid: backup_id)
      { algorithm: backup.checksum_algorithm, value: backup.artifact_checksum }
    end

    def self.pin(*) = raise(UnsupportedOperation, "pinning is not available yet")
    def self.release_pin(*) = raise(UnsupportedOperation, "pinning is not available yet")
    def self.record_replication(*) = raise(UnsupportedOperation, "replication recording is not available yet")
  end
end
