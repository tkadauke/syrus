module RetentionPolicyExecutors
  class RuntimeImageBuildLog < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window

      scope = RuntimeImageBuildEvidence.where.not(log: nil).where(finished_at: ..(Time.current - window))
      purged = 0
      max_batches.times do
        ids = scope.limit(batch_size).pluck(:id)
        break if ids.empty?
        purged += RuntimeImageBuildEvidence.where(id: ids).update_all(log: nil, updated_at: Time.current)
      end
      Result.new(deleted_count: purged, backlog: scope.exists?)
    end
  end
end
