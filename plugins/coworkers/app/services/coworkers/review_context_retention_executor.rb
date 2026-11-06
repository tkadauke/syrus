class Coworkers::ReviewContextRetentionExecutor < RetentionPolicyExecutors::Default

  def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
    window = @definition.retention_window
    return RetentionPolicyExecutors::Result.new(deleted_count: 0, backlog: false) unless window

    scope = @definition.model_class.public_send(@definition.scope_name).where(created_at: ...Time.current - window)
    records = scope.order(:id).limit(batch_size * max_batches).to_a
    records.each(&:tombstone!)
    RetentionPolicyExecutors::Result.new(deleted_count: records.size, backlog: scope.exists?)
  end
end
