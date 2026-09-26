# Backfill Landed Commit Records

Type: one-off backfill.

This task records `LandedCommit` rows for historical job and merge-train landings that happened before Syrus captured landed commit ranges reliably.

The task runs one repository at a time. For each repository, Syrus synchronizes the repository's bare clone, checks historical landed jobs and succeeded merge trains, and writes only missing landed commit rows. Existing rows are skipped, so the task is safe to resume.

If a repository still has landings that cannot be backfilled after its pass, the task records that repository under `checkpoint.unresolved_repositories`. Once the pass is exhausted, the task fails instead of reporting a clean success, so discovery leaves the failed task visible for operator follow-up instead of reviving the same work as a new pending task.

Why you might run it:

- Repository history shows Syrus-authored commits as unattributed direct pushes.
- Old landed jobs appear closed or deployed, but their commit history is incomplete.
- A new installation has imported historical Syrus jobs without landed commit ranges.

Expected load: moderate GitHub API and git usage per repository. Run during normal operation if the repository count is small; pause it if GitHub rate limits or bare-clone sync work competes with active landing.
