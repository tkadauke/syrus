module LocalBackups
  class ArtifactSource
    include Syrus::Host::BackupArtifactSource

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

    def self.open(backup_id, context:)
      backup = completed_backup!(backup_id)
      ArchiveStream.new.open(backup)
    end

    def self.checksum(backup_id, context:)
      backup = Backup.find_by!(uuid: backup_id)
      { algorithm: backup.checksum_algorithm, value: backup.artifact_checksum }
    end

    def self.pin(backup_id, owner:, context:)
      Backup.transaction do
        backup = Backup.lock.find_by!(uuid: backup_id, state: "completed")
        replication = backup.replications.find_or_initialize_by(destination_identity: owner.to_s)
        next false if replication.state == "verified"

        replication.update!(state: "uploading", failure_summary: nil)
        true
      end
    end

    def self.release_pin(backup_id, owner:, context:)
      backup = Backup.find_by!(uuid: backup_id)
      replication = backup.replications.find_by(destination_identity: owner.to_s)
      replication&.update!(state: "failed", failure_summary: "Replication ended before a result was recorded") if replication&.state == "uploading"
      true
    end

    def self.record_replication(backup_id, destination:, result:, context:)
      Backup.transaction do
        backup = Backup.lock.find_by!(uuid: backup_id)
        replication = backup.replications.find_or_initialize_by(destination_identity: destination.to_s)
        next true if replication.state == "verified" && result.fetch(:state).to_s != "verified"

        replication.update!(
          state: result.fetch(:state).to_s,
          remote_reference: result[:remote_reference],
          remote_checksum: result[:remote_checksum],
          uploaded_at: result[:uploaded_at],
          verified_at: result[:verified_at],
          failure_summary: redacted_summary(result[:failure_summary])
        )
        true
      end
    end

    def self.completed_backup!(backup_id)
      Backup.find_by!(uuid: backup_id, state: "completed")
    end
    private_class_method :completed_backup!

    def self.redacted_summary(value)
      value.to_s.gsub(%r{https?://\S+}, "[REDACTED_URL]").first(1000).presence
    end
    private_class_method :redacted_summary
  end
end
