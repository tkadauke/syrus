# Backfill WIP-Repair-Failure Flags

Type: one-off backfill.

`test_insight_cases.wip_repair_failure` marks a case that failed mid-way through an agent's grader retry loop but was fixed before the loop finished, so flakiness/failure-rate queries can exclude it with a plain indexed column read instead of the correlated `EXISTS` query it replaced. The flag is only ever written going forward, at ingest time (`TestInsights::Ingester`), so rows ingested before the column existed keep the default `false` -- correct for cases that were never superseded, wrong for the ones that were.

This task replays `TestInsights::WipRepairFailureClassifier` over historical `test_insight_runs` whose step is a grader-retry-loop iteration, oldest first. It only ever flips `wip_repair_failure` from `false` to `true`, so it is safe to run repeatedly or resume after a pause.

Why you might run it:

- Test Insights history predates the `wip_repair_failure` column and flakiness/failure-rate numbers should reflect it.
- A prior run of this task was cancelled or paused partway through.

Expected load: one indexed query per batch of `test_insight_runs`, plus one narrow `UPDATE` per batch. No table scans.
