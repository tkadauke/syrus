# External PR ingestion recovery

Use the backfill task after upgrading an installation that may still contain
issue Jobs closed as preempted when an open external pull request took over:

```bash
DRY_RUN=true bin/rails syrus:backfill_preempted_external_pr_jobs
bin/rails syrus:backfill_preempted_external_pr_jobs
```

The dry run reports how many records would change. The live run checks each
eligible Job against GitHub and reopens it as implemented only when its external
pull request is still open and unmerged. Merged, closed, and unavailable pull
requests are skipped.

This is an upgrade/recovery procedure, not part of normal external-PR usage.
The supported behavior is documented in
[`config/syrus_docs/external_pr_ingestion.md`](../../../config/syrus_docs/external_pr_ingestion.md).
