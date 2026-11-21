module S3BackupDestination
  class Subscriber
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions = { "local_backups.backup.completed" => :replicate }

    def self.replicate(event)
      backup_id = event[:backup_uuid] || event[:backup_id]
      source = Syrus::Host::PluginRegistry.providers_for(:backup_artifact_source).first
      return unless source && backup_id.present?

      lease_token = source.pin(backup_id, owner: Destination::IDENTITY, context: nil)
      return unless lease_token
      lease_context = { lease_token: }
      description = source.describe(backup_id, context: nil)
      io = source.open(backup_id, context: nil)
      uploaded = Destination.upload(description.merge(io:))
      verified = Destination.verify(uploaded.fetch(:remote_reference), expected_checksum: uploaded.fetch(:checksum))
      now = Time.current
      source.record_replication(backup_id, destination: Destination::IDENTITY, context: lease_context, result: {
        state: "verified", remote_reference: uploaded.fetch(:remote_reference), remote_checksum: verified.fetch(:checksum),
        uploaded_at: now, verified_at: now
      })
    rescue StandardError => error
      source&.record_replication(backup_id, destination: Destination::IDENTITY, context: lease_context, result: {
        state: "failed", failure_summary: Destination.send(:redacted, error)
      }) if lease_context
    ensure
      if source && backup_id.present? && lease_context
        source.release_pin(backup_id, owner: Destination::IDENTITY, context: lease_context)
      end
    end
  end
end
