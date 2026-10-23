# Age-based retention sweep for the plugin's raw execution history.
# `test_insight_cases` is by far the plugin's highest-volume table (one row
# per test example per grader run) and had no retention job anywhere in the
# codebase. Scope is deliberately age-only, matching the established
# `prunable`/`RETAIN_AFTER` shape used by RunDiagnostic and friends -- a
# per-`test_identity_id` row-count cap would need per-identity
# ranking/windowing, real added complexity for marginal benefit here.
#
# `test_insight_runs` uses its own age cutoff, but a run is deleted only after
# the bounded case sweep has removed all of its cases. This preserves the
# child-first invariant even when a large backlog spans multiple job ticks.
#
# Scheduled via the plugin's own tick (see TestInsights::Callbacks) rather
# than the host's config/recurring.yml, so disabling/removing the plugin
# removes the schedule with it.
class TestInsightsPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  DELETE_BATCH_SIZE = 1_000
  MAX_DELETE_BATCHES = 100

  def perform
    cases_deleted = prune(TestInsights::TestCase)
    Rails.logger.info("[TestInsightsPruneJob] deleted #{cases_deleted} test_insight_cases") if cases_deleted > 0

    runs_deleted = prune_runs_without_cases
    Rails.logger.info("[TestInsightsPruneJob] deleted #{runs_deleted} test_insight_runs") if runs_deleted > 0

    isolated_repro_attempts_deleted = prune(TestInsights::IsolatedReproAttempt)
    if isolated_repro_attempts_deleted > 0
      Rails.logger.info("[TestInsightsPruneJob] deleted #{isolated_repro_attempts_deleted} test_insight_isolated_repro_attempts")
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
      candidate_ids = TestInsights::TestRun.prunable.reorder(:created_at, :id).limit(DELETE_BATCH_SIZE).pluck(:id)
      break if candidate_ids.empty?

      occupied_ids = TestInsights::TestCase.where(test_run_id: candidate_ids).distinct.pluck(:test_run_id)
      empty_ids = candidate_ids - occupied_ids
      break if empty_ids.empty?

      deleted += TestInsights::TestRun.where(id: empty_ids).delete_all
    end
    deleted
  end
end
