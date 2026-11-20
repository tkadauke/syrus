module LocalBackups
  class Retention
    Result = Data.define(:deleted, :blocked)

    def initialize(root: StorageRoot.new, keep_count: ENV.fetch("SYRUS_BACKUP_KEEP_COUNT", 7).to_i,
      keep_days: ENV.fetch("SYRUS_BACKUP_KEEP_DAYS", 14).to_i,
      max_bytes: ENV.fetch("SYRUS_BACKUP_MAX_BYTES", 0).to_i,
      require_replication: ENV["SYRUS_BACKUP_REQUIRE_VERIFIED_REPLICATION"] == "1", clock: -> { Time.current })
      @root, @keep_count, @keep_days, @max_bytes, @require_replication, @clock =
        root, keep_count, keep_days, max_bytes, require_replication, clock
    end

    def call
      completed = Backup.where(state: "completed").includes(:replications).order(completed_at: :desc).to_a
      protected = protected_backup(completed)
      total = completed.sum(&:stored_bytes)
      deleted = []
      blocked = []
      completed.each_with_index do |backup, index|
        next unless over_limit?(backup, index:, total:)
        if ineligible?(backup, protected:)
          blocked << backup.uuid
          next
        end

        bytes = backup.stored_bytes
        delete!(backup, protected:)
        total -= bytes
        deleted << backup.uuid
      end
      OperationalEvents.emit("retention", deleted_count: deleted.length, blocked_count: blocked.length)
      Result.new(deleted:, blocked:)
    end

    def eligible?(backup)
      completed = Backup.where(state: "completed").includes(:replications).order(completed_at: :desc).to_a
      candidate = completed.find { |record| record.id == backup.id }
      candidate.present? && !ineligible?(candidate, protected: protected_backup(completed))
    end

    def reclaim!(bytes:)
      remaining = bytes
      completed = Backup.where(state: "completed").includes(:replications).order(completed_at: :desc).to_a
      protected = protected_backup(completed)
      deleted = []
      completed.reverse_each do |backup|
        next if ineligible?(backup, protected:)

        delete!(backup, protected:)
        deleted << backup.uuid
        remaining -= backup.stored_bytes
        break unless remaining.positive?
      end
      OperationalEvents.emit("reclamation_blocked", required_bytes: remaining) if remaining.positive?
      Result.new(deleted:, blocked: remaining.positive? ? completed.filter_map { |backup| backup.uuid if ineligible?(backup, protected:) } : [])
    end

    def delete!(backup, protected: nil)
      claim_deletion!(backup, protected:)

      begin
        FileUtils.remove_entry_secure(@root.contained(backup.artifact_relative_path))
      rescue Errno::ENOENT
        nil
      rescue StorageRoot::Invalid => e
        raise unless e.message == "artifact path does not exist"
      rescue StandardError
        Backup.where(id: backup.id, state: "deleting").update_all(state: "completed", updated_at: @clock.call)
        raise
      end
      Backup.where(id: backup.id, state: "deleting").update_all(state: "deleted", updated_at: @clock.call)
      OperationalEvents.emit("deleted", backup_uuid: backup.uuid, stored_bytes: backup.stored_bytes)
    end

    private

    def over_limit?(backup, index:, total:)
      index >= @keep_count || backup.completed_at < @keep_days.days.ago(@clock.call) || (@max_bytes.positive? && total > @max_bytes)
    end

    def ineligible?(backup, protected:)
      backup.state != "completed" || backup.pinned? || backup == protected ||
        (@require_replication && backup.replications.none? { |replication| replication.state == "verified" })
    end

    def protected_backup(completed)
      completed.find { |backup| backup.verification_state == "valid" } || completed.first
    end

    # The lock makes the protection decision and tombstone transition one
    # operation. Pin/unpin uses the same row lock, so a successful pin can
    # never be overtaken by an already-approved deletion.
    def claim_deletion!(backup, protected:)
      if protected
        raise ArgumentError, "backup is protected from deletion" if ineligible?(backup, protected:)
        claimed = Backup.where(id: backup.id, state: "completed", pinned: false)
          .update_all(state: "deleting", updated_at: @clock.call)
        raise ArgumentError, "backup is no longer eligible for deletion" unless claimed == 1
        return
      end

      Backup.transaction do
        completed = Backup.lock.where(state: "completed").includes(:replications).order(completed_at: :desc).to_a
        candidate = completed.find { |record| record.id == backup.id }
        raise ArgumentError, "backup is protected from deletion" unless candidate && !ineligible?(candidate, protected: protected_backup(completed))

        candidate.update!(state: "deleting")
      end
    end
  end
end
