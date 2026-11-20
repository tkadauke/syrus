require "set"

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
      candidate_ids = []
      blocked = []
      completed.each_with_index do |backup, index|
        next unless over_limit?(backup, index:, total:)
        if ineligible?(backup, protected:)
          blocked << backup.uuid
          next
        end

        candidate_ids << backup.id
        total -= backup.stored_bytes
      end
      claimed = claim_deletions!(candidate_ids)
      blocked.concat((candidate_ids - claimed.map(&:id)).filter_map { |id| completed.find { |backup| backup.id == id }&.uuid })
      delete_claimed_batch!(claimed)
      deleted = claimed.map(&:uuid)
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
      candidate_ids = []
      completed.reverse_each do |backup|
        next if ineligible?(backup, protected:)

        candidate_ids << backup.id
        remaining -= backup.stored_bytes
        break unless remaining.positive?
      end
      claimed = claim_deletions!(candidate_ids)
      delete_claimed_batch!(claimed)
      deleted = claimed.map(&:uuid)
      remaining += (candidate_ids - claimed.map(&:id)).sum { |id| completed.find { |backup| backup.id == id }&.stored_bytes.to_i }
      OperationalEvents.emit("reclamation_blocked", required_bytes: remaining) if remaining.positive?
      newly_blocked = candidate_ids - claimed.map(&:id)
      blocked = completed.filter_map { |backup| backup.uuid if ineligible?(backup, protected:) || newly_blocked.include?(backup.id) }
      Result.new(deleted:, blocked: remaining.positive? ? blocked : [])
    end

    def delete!(backup)
      claimed = claim_deletions!([backup.id]).first
      raise ArgumentError, "backup is protected from deletion" unless claimed

      delete_claimed!(claimed)
    end

    private

    def delete_claimed_batch!(backups)
      backups.each_with_index do |backup, index|
        delete_claimed!(backup)
      rescue StandardError
        remaining_ids = backups.drop(index + 1).map(&:id)
        Backup.where(id: remaining_ids, state: "deleting").update_all(state: "completed", updated_at: @clock.call)
        raise
      end
    end

    def delete_claimed!(backup)
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

    # Claim a sweep's candidates together so every safety gate is evaluated
    # from one locked, current view without per-backup eligibility queries.
    def claim_deletions!(candidate_ids)
      return [] if candidate_ids.empty?

      Backup.transaction do
        completed = Backup.lock.where(state: "completed").order(completed_at: :desc).to_a
        Replication.lock.where(backup_id: completed.map(&:id)).load
        verified_ids = Replication.where(backup_id: completed.map(&:id), state: "verified").distinct.pluck(:backup_id).to_set
        protected = protected_backup(completed)
        candidates = completed.select do |backup|
          candidate_ids.include?(backup.id) && !backup.pinned? && backup != protected &&
            (!@require_replication || verified_ids.include?(backup.id))
        end
        candidates.each { |backup| backup.update!(state: "deleting") }
        candidates
      end
    end
  end
end
