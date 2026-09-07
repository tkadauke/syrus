# Forks and upstreams

A repository can be registered as a **fork** of an **upstream** repository that
also lives in this Syrus instance (typically under a different user). Set the
fork's upstream on the repository form (`upstream_owner` / `upstream_name`); when
the upstream is a repository Syrus already knows, the two are linked by
`upstream_repository_id`.

**Onboarding auto-detects GitHub forks.** When adding a repository, if the
selected GitHub repository is itself a fork, the Add Repository modal pre-fills
`upstream_owner`, `upstream_name`, and `upstream_default_branch` from GitHub's
fork metadata (`GithubClient#owner_repos` returns `fork`/`parent_full_name`/
`parent_default_branch`, fetching the individual repo only for repos flagged as
forks when the list endpoint omits `parent`). This is a default, not a
decision — the fields stay editable and can be cleared before submitting, and a
non-fork repository's upstream fields stay blank exactly as before. Detection
failures (rate limits, GitHub errors) degrade silently; the modal still
submits without upstream fields. This does not retroactively detect upstreams
for repositories already added.

## Jobs on a fork branch off the upstream's default branch

For a fork whose upstream is registered in the instance, Jobs base their work on
the **upstream's default branch**, not the fork's:

- The workspace clones the fork, fetches the upstream's default branch, and
  creates the work branch off the upstream's tip.
- The agent diff (three-dot `git diff <base>...HEAD`) is measured against the
  upstream's default branch.
- The pull request is opened **directly on the upstream** — head = the fork's
  branch, base = the upstream's default branch (`pr_repository` is set to the
  upstream). There is no staging PR on the fork.

This is driven by `Job#base_on_upstream_default?`. It does not apply to:

- non-forks,
- forks whose upstream is only an external slug not registered in this instance
  (those still branch off the fork's own default), or
- stacked child Jobs (which base on their parent branch).

Credentials for fetching a **private** upstream are out of scope for now — the
upstream fetch is anonymous, so this works for public upstreams.

## Keeping the fork's own default branch current (auto-sync)

Independent of Jobs, a fork's **own** default branch can be kept in sync with its
upstream so main-branch health and grader detection on the fork do not run
against stale code.

- **Setting:** `Repository#fork_auto_sync_enabled` (default **off**). When on,
  `SyncEnabledForksJob` (scheduled every 15 minutes) enqueues a `SyncForkJob`
  for the fork, which syncs the fork's default branch from the upstream via
  GitHub's merge-upstream API (no local clone).
- **Manual "Sync now":** the repository settings form shows a **Sync now** button
  for any fork with an in-instance upstream, regardless of the auto-sync toggle.
  It enqueues the same `SyncForkJob` immediately
  (`POST /api/v1/app/repositories/:id/sync_fork`).
- A merge conflict or a non-syncable repository is reported and logged; it does
  not raise. The sync is best-effort.

Auto-sync is purely about the fork's own branch freshness. It is **not** required
for Jobs to be correct — Jobs already branch off the upstream directly.
