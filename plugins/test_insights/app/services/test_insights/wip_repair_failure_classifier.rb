module TestInsights
  # Flags earlier failing test_insight_cases as "WIP repair failures" -- cases
  # that failed mid-way through an agent's grader retry loop but were fixed
  # before the loop finished -- so TestCase.scored (flakiness/failure-rate
  # history) can exclude them with a plain indexed column read instead of the
  # correlated EXISTS query this replaces (TestCase#later_passing_grader_case_exists_sql,
  # removed). That query let MySQL's optimizer flatten the EXISTS into a
  # semi-join across test_insight_cases/test_insight_runs/runs/steps and pick a
  # join order that ignored the test_identity_id index entirely, turning a
  # handful of relevant rows into a multi-billion-row scan.
  #
  # `mark_superseded!` is called once per grader-run ingestion (see
  # TestInsights::Ingester) and is the only write path for the flag: a case
  # starts scored (wip_repair_failure: false) and only ever flips to true, the
  # moment a *later* iteration of the same retry loop, for the same test
  # identity and grader, records a pass. That later-iteration requirement is
  # exactly what the removed EXISTS checked, just computed forward at ingest
  # time instead of backward at every read.
  class WipRepairFailureClassifier
    def self.mark_superseded!(test_run:, step:)
      new(test_run: test_run, step: step).mark_superseded!
    end

    def initialize(test_run:, step:)
      @test_run = test_run
      @step = step
    end

    def mark_superseded!
      return 0 unless retry_loop_grader_step?
      return 0 if passed_identity_ids.empty?

      PerformanceLogging.phase("test_insights.mark_wip_repair_failures", workflow_id: @step.workflow_id) do
        TestCase
          .joins(test_run: { run: :step })
          .where(test_identity_id: passed_identity_ids)
          .failure_like
          .where(wip_repair_failure: false)
          .where(test_insight_runs: { grader_name: @test_run.grader_name })
          .where(steps: { kind: "grader", workflow_id: @step.workflow_id, loop_id: @step.loop_id })
          .where("steps.iteration < ?", @step.iteration)
          .update_all(wip_repair_failure: true, updated_at: Time.current)
      end
    end

    private

    def retry_loop_grader_step?
      @step.present? && @step.kind == "grader" && @step.loop_id.present?
    end

    def passed_identity_ids
      @passed_identity_ids ||= TestCase
        .where(test_run_id: @test_run.id, status: "passed")
        .where.not(test_identity_id: nil)
        .distinct
        .pluck(:test_identity_id)
    end
  end
end
