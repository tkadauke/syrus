# Age-based retention sweep for the plugin's raw execution history.
# `test_insight_cases` is by far the plugin's highest-volume table (one row
# per test example per grader run) and had no retention job anywhere in the
# codebase. Scope is deliberately age-only, matching the established
# `prunable`/`RETAIN_AFTER` shape used by RunDiagnostic and friends -- a
# per-`test_identity_id` row-count cap would need per-identity
# ranking/windowing, real added complexity for marginal benefit here.
#
# `test_insight_runs` is pruned independently by its own age rather than only
# emptying out as a side effect of its cases being deleted -- see
# TestInsights::TestRun::RETAIN_AFTER.
#
# Scheduled via the plugin's own tick (see TestInsights::Callbacks) rather
# than the host's config/recurring.yml, so disabling/removing the plugin
# removes the schedule with it.
class TestInsightsPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    cases_deleted = TestInsights::TestCase.prunable.delete_all
    Rails.logger.info("[TestInsightsPruneJob] deleted #{cases_deleted} test_insight_cases") if cases_deleted > 0

    runs_deleted = TestInsights::TestRun.prunable.delete_all
    Rails.logger.info("[TestInsightsPruneJob] deleted #{runs_deleted} test_insight_runs") if runs_deleted > 0

    isolated_repro_attempts_deleted = TestInsights::IsolatedReproAttempt.prunable.delete_all
    if isolated_repro_attempts_deleted > 0
      Rails.logger.info("[TestInsightsPruneJob] deleted #{isolated_repro_attempts_deleted} test_insight_isolated_repro_attempts")
    end
  end
end
