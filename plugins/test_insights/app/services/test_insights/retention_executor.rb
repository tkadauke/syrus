module TestInsights
  class RetentionExecutor < RetentionPolicyExecutors::Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      result = super
      dependent_deleted = prune_empty_runs(batch_size:, max_batches:) + prune_attempts(batch_size:, max_batches:)
      RetentionPolicyExecutors::Result.new(
        deleted_count: result.deleted_count + dependent_deleted,
        backlog: result.backlog || dependent_backlog?
      )
    end

    private

    def prune_empty_runs(batch_size:, max_batches:)
      deleted = 0
      max_batches.times do
        ids = TestRun.prunable.where.not(id: TestCase.select(:test_run_id)).reorder(:created_at, :id).limit(batch_size).pluck(:id)
        break if ids.empty?

        deleted += TestRun.where(id: ids).delete_all
      end
      deleted
    end

    def prune_attempts(batch_size:, max_batches:)
      deleted = 0
      max_batches.times do
        ids = IsolatedReproAttempt.prunable.reorder(:created_at, :id).limit(batch_size).pluck(:id)
        break if ids.empty?

        deleted += IsolatedReproAttempt.where(id: ids).delete_all
      end
      deleted
    end

    def dependent_backlog?
      IsolatedReproAttempt.prunable.exists? ||
        TestRun.prunable.where.not(id: TestCase.select(:test_run_id)).exists?
    end
  end
end
