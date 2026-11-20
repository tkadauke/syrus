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
      completed = Backup.where(state: "completed").order(completed_at: :desc).to_a
      protected = completed.first
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
        delete!(backup)
        total -= bytes
        deleted << backup.uuid
      end
      Result.new(deleted:, blocked:)
    end

    def eligible?(backup)
      newest = Backup.where(state: "completed", verification_state: "valid").order(completed_at: :desc).first
      !ineligible?(backup, protected: newest)
    end

    def delete!(backup)
      raise ArgumentError, "backup is protected from deletion" unless eligible?(backup)

      backup.update!(state: "deleting")
      FileUtils.remove_entry_secure(@root.contained(backup.artifact_relative_path))
      backup.update!(state: "deleted")
    end

    private

    def over_limit?(backup, index:, total:)
      index >= @keep_count || backup.completed_at < @keep_days.days.ago(@clock.call) || (@max_bytes.positive? && total > @max_bytes)
    end

    def ineligible?(backup, protected:)
      backup != Backup.find_by(id: backup.id) || backup.state != "completed" || backup.pinned? || backup == protected ||
        (@require_replication && !backup.replications.where(state: "verified").exists?)
    end
  end
end
