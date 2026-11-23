module LocalBackups
  # Releases uploads nobody will finish (NY21). Retention never deletes a
  # backup with an "uploading" replication, and a replication whose worker died
  # stays "uploading" until the same destination pins the backup again. When
  # that destination is gone, the backup was protected from retention and
  # capacity reclamation forever.
  #
  # A replication is abandoned when its lease has expired and no enabled
  # destination claims its identity while configured. Deletion stays
  # conservative: while any enabled destination does not declare which
  # identity it owns, it might own any upload, and nothing is released.
  class AbandonedReplicationSweep
    SUMMARY = "Upload abandoned: its lease expired and its destination is no longer configured".freeze

    def call(now: Time.current)
      claimed = claimed_identities
      return [] unless claimed

      expired(now).filter_map do |replication|
        next if claimed.include?(replication.destination_identity)

        release(replication, now:)
      end
    end

    private

    # The identities enabled, configured destinations own, or nil when an
    # enabled destination does not say.
    def claimed_identities
      destinations = Syrus::Host::PluginRegistry.providers_for(:backup_destination)
      return nil if destinations.any? { |destination| identity_of(destination).blank? }

      destinations.select { |destination| configured?(destination) }.map { |destination| identity_of(destination) }.to_set
    end

    def identity_of(destination)
      destination.respond_to?(:identity) ? destination.identity.to_s.presence : nil
    end

    # A destination that cannot answer is treated as configured: it keeps its
    # uploads.
    def configured?(destination)
      !destination.respond_to?(:configured?) || destination.configured?
    rescue StandardError
      true
    end

    def expired(now)
      Replication.where(state: "uploading").where("lease_expires_at IS NULL OR lease_expires_at <= ?", now).to_a
    end

    # Backup before replication, as ArtifactSource.pin locks them, and the
    # state rechecked under the lock: a destination may have pinned again.
    def release(replication, now:)
      Backup.transaction do
        Backup.lock.find(replication.backup_id)
        replication.lock!
        next unless replication.state == "uploading"
        next if replication.lease_expires_at.present? && replication.lease_expires_at > now

        replication.update!(state: "failed", failure_summary: SUMMARY, lease_token: nil, lease_expires_at: nil)
        replication.id
      end
    end
  end
end
