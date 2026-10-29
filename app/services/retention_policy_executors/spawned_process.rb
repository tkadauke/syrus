module RetentionPolicyExecutors
  class SpawnedProcess < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      cutoff = retention_cutoff
      return Result.new(deleted_count: 0, backlog: false) unless cutoff

      scope = @definition.model_class.public_send(@definition.scope_name)
      deleted = 0
      max_batches.times do
        ids = scope.reorder(id: :asc).limit(batch_size).pluck(:id)
        break if ids.empty?

        ::SpawnedProcess.transaction do
          CommandSpan.where(spawned_process_id: ids).update_all(spawned_process_id: nil) # rubocop:disable Rails/SkipsModelValidations
          deleted += ::SpawnedProcess.where(id: ids).delete_all
        end
      end
      Result.new(deleted_count: deleted, backlog: scope.exists?)
    end
  end
end
