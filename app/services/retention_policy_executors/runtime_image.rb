module RetentionPolicyExecutors
  # Garbage-collects expired runtime images through the Runtime Image Service
  # (provider delete first, record tombstone second) instead of deleting
  # rows: deleted records stay so a digest can never be republished.
  class RuntimeImage < Default
    def call(batch_size: nil, max_batches: nil)
      window = @definition.retention_window
      result = ::RuntimeImages::Collector.new(global_window: window).call
      Result.new(deleted_count: result.deleted, backlog: result.backlog)
    end
  end
end
