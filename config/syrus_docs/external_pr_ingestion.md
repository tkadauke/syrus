# External PR Ingestion

When `PollRepositoryJob` sees a labeled GitHub issue with a linked open PR
that Syrus did not create, it records the relationship on the issue-backed
Job with `external_pr_number`.

Newly discovered issues with linked external PRs are created as normal
`issue` Jobs in `implemented` state. Syrus does not start an agent workflow
for them; the external PR is already the implementation under review.

Existing open issue Jobs that later gain a linked external PR are moved to
`implemented`, have active Runs cancelled, and keep `external_pr_number` set.
This replaces the older `closed` / `preempted` behavior so operators can
review the Job instead of losing it to a terminal state.

To backfill older data, run:

```bash
bin/rails syrus:backfill_preempted_external_pr_jobs
```

The task checks each closed `issue` Job with `closure_reason = preempted` and
an `external_pr_number` against GitHub. If the external PR is still open and
unmerged, the task reopens the Job to `implemented`. It skips PRs that are
already merged, closed, or unavailable. Use `DRY_RUN=true` to count the
changes without modifying Jobs.
