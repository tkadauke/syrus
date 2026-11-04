module RetentionPolicyExecutors
  class VisualEvidence < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window

      scope = @definition.model_class.public_send(@definition.scope_name).where(captured_at: ...Time.current - window)
      records = scope.order(:id).limit(batch_size * max_batches).to_a
      records.each do |evidence|
        evidence.image.purge
        evidence.destroy!
      end
      Result.new(deleted_count: records.size, backlog: scope.exists?)
    end
  end
end
