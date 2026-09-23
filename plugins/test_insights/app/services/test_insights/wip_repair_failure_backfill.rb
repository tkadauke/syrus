module TestInsights
  # One-time (operator-triggered) backfill for TestInsights::WipRepairFailureClassifier.
  # Driven by MaintenanceTasks::Definitions::TestInsightsWipRepairFailureBackfill.
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
  class WipRepairFailureBackfill
    Result = Struct.new(:done, :processed, :next_after_id, keyword_init: true)

    def self.pending_count = new.pending_count

    def pending_count
      candidate_test_runs(0).count
    end

    def call(after_id: 0, limit:)
      test_runs = candidate_test_runs(after_id).limit(limit).to_a
      return Result.new(done: true, processed: 0, next_after_id: after_id) if test_runs.empty?

      test_runs.each do |test_run|
        TestInsights::WipRepairFailureClassifier.mark_superseded!(test_run: test_run, step: test_run.run.step)
      end

      Result.new(done: false, processed: test_runs.size, next_after_id: test_runs.last.id)
    end

    private

    def candidate_test_runs(after_id)
      TestInsights::TestRun
        .joins(run: :step)
        .where(steps: { kind: "grader" })
        .where.not(steps: { loop_id: nil })
        .where("test_insight_runs.id > ?", after_id)
        .order(:id)
        .includes(run: :step)
    end
  end
end
