# Backfill WIP-Repair-Failure Flags

Type: one-off backfill.

`test_insight_cases.wip_repair_failure` marks a case that failed mid-way through an agent's grader retry loop but was fixed before the loop finished, so flakiness/failure-rate queries can exclude it with a plain indexed column read instead of the correlated `EXISTS` query it replaced. The flag is only ever written going forward, at ingest time (`TestInsights::Ingester`), so rows ingested before the column existed keep the default `false` -- correct for cases that were never superseded, wrong for the ones that were.

This task replays `TestInsights::WipRepairFailureClassifier` over a bounded historical set of `test_insight_runs` whose step is a grader-retry-loop iteration and that have durable `test_insight_cases`, oldest first. The detector records `upper_bound_test_run_id` in the task checkpoint when it creates or revives the task, and each batch only walks rows up to that id. Zero-case runs are skipped because a case-level flag cannot change them.

After the bounded pass completes, later live grader-loop rows do not make this one-off task reappear. Normal ingestion (`TestInsights::Ingester`) handles those rows as they arrive by calling the same classifier. If a historical pass is paused, cancelled, or retried before completion, the task can resume from its `after_id` checkpoint within the original `upper_bound_test_run_id`.

It only ever flips `wip_repair_failure` from `false` to `true`, so it is safe to run repeatedly or resume after a pause.

Why you might run it:

- Test Insights history predates the `wip_repair_failure` column and flakiness/failure-rate numbers should reflect it.
- A prior run of this task was cancelled or paused partway through.

Expected load: one indexed query per batch of `test_insight_runs`, plus one narrow `UPDATE` per batch. No table scans.
