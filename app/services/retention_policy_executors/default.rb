module RetentionPolicyExecutors
  Result = Data.define(:deleted_count, :backlog)

  class Default
    def initialize(definition)
      @definition = definition
    end

    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      cutoff = retention_cutoff
      return Result.new(deleted_count: 0, backlog: false) unless cutoff

      scope = @definition.model_class.public_send(@definition.scope_name)
      archive_key = @definition.key if @definition.archivable
      deleted = RetentionPruner.call(
        scope: scope,
        retention_key: archive_key,
        cutoff: cutoff,
        batch_size: batch_size,
        max_batches: max_batches
      )
      Result.new(deleted_count: deleted, backlog: scope.exists?)
    end

    private

    def retention_cutoff
      window = @definition.retention_window
      window && Time.current - window
    end
  end
end
