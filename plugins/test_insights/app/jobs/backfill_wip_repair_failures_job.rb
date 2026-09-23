# One-time (operator-triggered) backfill for TestInsights::WipRepairFailureClassifier.
#
# `wip_repair_failure` is only ever written going forward, at ingest time (see
# TestInsights::Ingester). Rows ingested before that column existed keep their
# default `false` -- correct for cases that were never superseded, wrong for
# the ones that were -- until this replays classification over history.
#
# Deliberately does NOT reuse the old correlated-EXISTS query
# (TestCase#later_passing_grader_case_exists_sql, removed): that query is what
# this feature replaces, and replaying it at any scale would hit the exact
# MySQL semi-join blowup this backfill exists to avoid. Instead it walks
# test_insight_runs whose step is a grader-retry-loop iteration, oldest first,
# and calls the same narrow, indexed classifier the live ingestion path uses.
# Safe to run repeatedly: each call only ever flips wip_repair_failure from
# false to true, never the reverse.
class BackfillWipRepairFailuresJob < ApplicationJob
  queue_as :low_priority_maintenance

  BATCH_SIZE = 200

  limits_concurrency to: 1, key: -> { "test_insights:backfill_wip_repair_failures" }, on_conflict: :discard

  def perform(after_id: 0)
    test_runs = candidate_test_runs(after_id).to_a
    return if test_runs.empty?

    test_runs.each do |test_run|
      TestInsights::WipRepairFailureClassifier.mark_superseded!(test_run: test_run, step: test_run.run.step)
    end

    self.class.perform_later(after_id: test_runs.last.id)
  end

  private

  def candidate_test_runs(after_id)
    TestInsights::TestRun
      .joins(run: :step)
      .where(steps: { kind: "grader" })
      .where.not(steps: { loop_id: nil })
      .where("test_insight_runs.id > ?", after_id)
      .order(:id)
      .limit(BATCH_SIZE)
      .includes(run: :step)
  end
end
