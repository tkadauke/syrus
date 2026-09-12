# Recover Preempted External PR Jobs

Type: one-off repair.

This task checks historical jobs that Syrus closed as `preempted` while tracking an external pull request. If the external PR is still open and unmerged, the task reopens the Syrus job into the externally implemented state so normal polling and landing can resume.

Why you might run it:

- External PR ingestion previously closed a job too aggressively.
- A visible PR is still open, but the corresponding Syrus job is no longer active.

Expected load: one GitHub pull-request lookup per candidate job. Jobs whose PR is closed, merged, or missing are skipped and logged.
