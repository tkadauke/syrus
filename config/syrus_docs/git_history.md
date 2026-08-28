# Git History

The Git History tab (`plugins/git_history`) shows a repository's full commit
history, newest first, with each commit attributed back to the Syrus
Job/Epic/chat/issue/cron task that landed it (or marked as an external PR or
raw push when Syrus didn't author it). It's an always-on plugin
(`default_enabled: true`); operators can disable it per-instance like any
other plugin.

## Data source

Commit data comes from `RepositoryBareClone`, the per-repository bare clone
Syrus already maintains at `$SYRUS_DATA_ROOT/clones/<repo_id>.git` for other
purposes (rebase preflight, stack rebases). `RepositoryBareClone#sync!` only
ever runs from `PollMergeStateJob` / `PollPullRequestJob` /
`LandingQueueRecheck` — all processed on the `polling` queue, i.e. **worker**
pods, which are the only pods with the `$SYRUS_DATA_ROOT` PVC mounted. Git
History never triggers a sync itself; a repository with no landed/reviewed
PRs yet simply reports `available: false` until the normal background pollers
populate the clone.

## Cross-pod relay

`Api::V1::App::GitHistoryController` is served by **web** pods, which do not
mount `$SYRUS_DATA_ROOT` and can't read the bare clone off local disk. Reads
are proxied to a worker pod instead, mirroring the `PreviewControlServer` /
`PreviewLogClient` pattern (not `ChatWorkspaceRelay`/`TerminalRelay` — this is
a stateless, `repository_id`-keyed read with no session to pin to):

- `GitHistory::RelayServer` — an internal-only HTTP server (Puma, JSON)
  started at boot from `GitHistory::Engine` on every process where
  `SyrusVersion.role == "worker"`. `RelayServer.ensure_running!` further
  gates on `WorkerQueueTopology.consumes?("polling")` — this process's own
  resolved Solid Queue worker config (respecting `SOLID_QUEUE_CONFIG`) —
  so it only actually starts on the worker pod(s) configured to consume the
  `polling` queue, the same queue `RepositoryBareClone#sync!` runs from (see
  below). A worker-role pod on a queue tier that never consumes `polling`
  (e.g. `config/queue.compute.yml`) never starts the relay at all, instead of
  starting one that would always answer `available: false`. It answers
  `available?` and paginated `git log` reads against whichever bare clones
  exist on *that worker's* own disk. Bound on a fixed port,
  `SYRUS_GIT_HISTORY_RELAY_PORT` (default `4571`), on the internal network
  only — never exposed through public ingress.
- `GitHistory::RelayClient` — called by `GitHistory::Commits` from the web
  pod instead of touching `RepositoryBareClone` directly. Talks to a fixed
  internal address, `SYRUS_GIT_HISTORY_INTERNAL_HOST` (default `127.0.0.1`,
  matching the `SYRUS_PREVIEW_INTERNAL_HOST` convention), at the relay's
  fixed port. No per-request credential — `GitHistoryController` already
  authorizes the request (`Repository.accessible_to(Current.user)`) before
  proxying.

A relay that's unreachable, times out, or errors degrades to
`available: false` — the same graceful "not available yet" the tab already
shows for a repository whose bare clone hasn't synced. It is never surfaced
as a hard error to the operator.

**Single-writer-pod assumption.** See `config/syrus_docs/multi_worker.md`'s
"Git History relay pinning" section: today exactly one worker pod ever syncs
bare clones (`polling` is conventionally bundled onto the single home worker),
so the relay running only on the pod(s) consuming `polling` is correct by
construction. If `polling` is ever split across more than one pod, this relay
design needs revisiting — nothing currently records which pod holds a given
repository's synced clone the way `ChatSession#coding_relay_address` does for
coding checkouts.

## Diagnostics

Before `WorkerQueueTopology` gating existed, a misconfigured queue split
(every worker tier missing `polling`) degraded silently: the relay looked
"reachable" but never useful, and `available: false` was indistinguishable
from a repository that just hadn't synced yet. `PollingQueueCoverageCheckJob`
(recurring, every 5 minutes, `cleanup` queue) checks whether *any* live
`SolidQueue::Process` worker in the fleet reports consuming the `polling`
queue (via `SolidQueue::Process#metadata["queues"]`) and logs a structured
`Rails.logger.error` line if none do — the same failure mode this issue was
filed to fix, but now loud instead of silent. This check is deliberately
generic rather than Git-History-specific: a fleet with zero `polling`
consumers has also stopped ingesting GitHub issues and PR feedback entirely,
which is the bigger operational problem.

## Attribution

`GitHistory::CommitAttributor` classifies each commit and stays on the web
pod (it needs `Current.user`/DB access the relay doesn't have). Classification
is driven primarily by the `landed_commits` table — the per-commit record a
Job or Epic writes at landing time (`Steps::AutoMerge`, `Steps::MergeTrainBuild`,
`Steps::MergeTrainLand`, `Steps::MergeTrainReconcile`) — with a fallback to the
older single-SHA `Job#landed_sha` match for history recorded before that table
existed:

- `syrus_landed` — sha has a `LandedCommit(landable: Job, kind:
  "implementation")` row, or — as the legacy fallback — matches a non-
  `external_pr` Job's `landed_sha` directly. Attributed to the creating user,
  Epic (if any), and origin (chat / GitHub issue / cron).
- `epic_landed` — sha has a `LandedCommit(landable: Epic, kind:
  "integration_merge")` row, written by `Steps::MergeTrainLand` for the single
  merge commit of an Epic merge-train landing. Attributed to the Epic plus the
  full list of member Jobs that landed through that integration commit
  (`Job.where(landed_sha: sha)` — every member still carries the same legacy
  `landed_sha`).
- `epic_reconciliation` — sha has a `LandedCommit(landable: Epic, kind:
  "reconcile")` row, written by `Steps::MergeTrainReconcile` when its pass
  actually commits changes on the integration branch. Attributed to the Epic
  only, no single Job.
- `external_pr` — no `LandedCommit` row; sha matches an `external_pr`-kind
  Job's `landed_sha` (`PollExternalPrJob` tracked someone else's PR that
  merged). Attributed to the raw GitHub author/committer, not a Syrus user.
- `external_push` — no `LandedCommit` row and no matching Job at all, a raw
  commit pushed straight to the default branch. Attributed to the raw GitHub
  author/committer.

Backfilling `LandedCommit` rows for history recorded before this table shipped
is a separate, deferred follow-up — until that runs, older commits keep
resolving through the `Job#landed_sha` fallback above.

Chat origin attribution redacts the chat session id/title unless the
requesting user can actually access that chat
(`User#accessible_chat_sessions`) — the commit is still marked chat-originated
either way, but the reference itself never leaks.

## Presentation

`GitHistory.tsx` groups the flat, cursor-paginated commit list
(`groupCommits.ts`) rather than rendering every commit as a flat row: an
`epic_landed` commit anchors a collapsible group for its Epic, nesting every
member Job's own `syrus_landed` commits underneath it as their own
sub-group; `epic_reconciliation` commits attach directly to their Epic's
group (never to a Job); a `syrus_landed` Job with no epic-landing commit in
view (a regular, non-merge-train landing, or a merge-train landing whose
integration commit hasn't loaded yet) still groups its own commits together
as a standalone Job group. `external_pr`/`external_push` commits are never
grouped — always in the list. Grouping is
recomputed from the *entire* accumulated commit list on every render (not
per-page), so a group split across a "load more" cursor boundary
reassembles automatically once the rest of its commits load, regardless of
where the boundary fell.

Syrus-attributed rows (`syrus_landed`/`epic_landed`/`epic_reconciliation`,
and anything they group) render with bold text and a terracotta left-border
accent; `external_pr`/`external_push` rows render de-emphasized (muted
gray text, no accent border) — the operator ask this satisfies is
"emphasize commits that are actual jobs over others."
