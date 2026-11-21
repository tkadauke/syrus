module LocalBackups
  class ArtifactSource
    include Syrus::Host::BackupArtifactSource

    LEASE_DURATION = 6.hours

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
      now = Time.current
      lease_token = SecureRandom.uuid
      Backup.transaction do
        backup = Backup.lock.find_by!(uuid: backup_id, state: "completed")
        replication = backup.replications.find_or_initialize_by(destination_identity: owner.to_s)
        next false if replication.state == "verified" || active_lease?(replication, now:)

        replication.update!(
          state: "uploading", failure_summary: nil, lease_token:, lease_expires_at: now + LEASE_DURATION
        )
        lease_token
      end
    end

    def self.release_pin(backup_id, owner:, context:)
      Backup.transaction do
        backup = Backup.lock.find_by!(uuid: backup_id)
        replication = backup.replications.find_by(destination_identity: owner.to_s)
        next false unless owns_lease?(replication, context:)

        replication.update!(
          state: "failed", failure_summary: "Replication ended before a result was recorded",
          lease_token: nil, lease_expires_at: nil
        )
        true
      end
    end

    def self.record_replication(backup_id, destination:, result:, context:)
      Backup.transaction do
        backup = Backup.lock.find_by!(uuid: backup_id)
        replication = backup.replications.find_or_initialize_by(destination_identity: destination.to_s)
        next false unless owns_lease?(replication, context:)

        replication.update!(
          state: result.fetch(:state).to_s,
          remote_reference: result[:remote_reference],
          remote_checksum: result[:remote_checksum],
          uploaded_at: result[:uploaded_at],
          verified_at: result[:verified_at],
          failure_summary: redacted_summary(result[:failure_summary]),
          lease_token: nil,
          lease_expires_at: nil
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

    def self.active_lease?(replication, now:)
      replication.state == "uploading" && replication.lease_expires_at.present? && replication.lease_expires_at > now
    end
    private_class_method :active_lease?

    def self.owns_lease?(replication, context:)
      token = context.is_a?(Hash) && (context[:lease_token] || context["lease_token"])
      replication&.state == "uploading" && token.present? && replication.lease_token == token
    end
    private_class_method :owns_lease?
  end
end
