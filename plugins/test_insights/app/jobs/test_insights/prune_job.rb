# Age-based retention sweep for the plugin's raw execution history. Cases are
# deleted in bounded batches before now-empty parent run rows. Isolated repro
# attempts retain their separate, shorter fixed window because they are
# immediate adjudication evidence rather than statistical test history.
module TestInsights
  class PruneJob < ApplicationJob
    include SkipIfPending

    queue_as :cleanup

    DELETE_BATCH_SIZE = 1_000
    MAX_DELETE_BATCHES = 100

    def perform
      cases_deleted = prune(TestCase)
      Rails.logger.info("[TestInsights::PruneJob] deleted #{cases_deleted} test_insight_cases") if cases_deleted.positive?

      runs_deleted = prune_runs_without_cases
      Rails.logger.info("[TestInsights::PruneJob] deleted #{runs_deleted} test_insight_runs") if runs_deleted.positive?

      attempts_deleted = prune(IsolatedReproAttempt)
      if attempts_deleted.positive?
        Rails.logger.info("[TestInsights::PruneJob] deleted #{attempts_deleted} test_insight_isolated_repro_attempts")
      end
    end

    private

    def prune(model)
      deleted = 0
      MAX_DELETE_BATCHES.times do
        ids = model.prunable.reorder(:created_at, :id).limit(DELETE_BATCH_SIZE).pluck(:id)
        break if ids.empty?

        deleted += model.where(id: ids).delete_all
      end
      deleted
    end

    def prune_runs_without_cases
      deleted = 0
      MAX_DELETE_BATCHES.times do
        candidate_ids = TestRun.prunable.reorder(:created_at, :id).limit(DELETE_BATCH_SIZE).pluck(:id)
        break if candidate_ids.empty?

        occupied_ids = TestCase.where(test_run_id: candidate_ids).distinct.pluck(:test_run_id)
        empty_ids = candidate_ids - occupied_ids
        break if empty_ids.empty?

        deleted += TestRun.where(id: empty_ids).delete_all
      end
      deleted
    end
  end
end
