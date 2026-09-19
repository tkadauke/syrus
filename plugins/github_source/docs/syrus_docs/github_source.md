# GitHub Source

The `github_source` plugin (`plugins/github_source/`) is Syrus' built-in
GitHub integration: issue/PR polling, PR operations, and source-control
primitives other workflows depend on. It is default-ON, customer-facing, and
category `input_source`, providing `input_source: "InputSources::Github"`,
`source_control_provider: "SourceControl::GithubOperations"`,
`repo_page_tab: "GithubSource::RepoPageTabs"`, and
`admin_page: "GithubSource::AdminPages"`.

## Disableable, with a runtime guard

`github_source` sets `disableable: true` — it is **not** hard-pinned enabled
the way a `disableable: false` plugin would be. What actually stops an
operator from disabling it while it's load-bearing is
`Admin::PluginDisableGuard`, which runs at disable time (not at boot) and
raises `Admin::PluginDisableGuard::Blocked` when any of the following are
non-zero for a provider this manifest provides:

- **`input_source` blockers** — `InputSource.where(type: "InputSources::Github").count`
  (configured GitHub input sources on any repository).
- **`source_control_provider` blockers** — every active `Repository` for
  which `SourceControl::GithubOperations.available_for?(repository)` is true
  (any repo whose slug looks like `owner/name`).

The guard is generic — it also checks `agent_provider`/`chat_provider`
blockers for any manifest that provides those — `github_source` just happens
to trip the `input_source`/`source_control_provider` branches since it is
the only plugin currently registering either. Disabling only succeeds once
every repository has migrated off GitHub-backed polling and PR operations
(or been archived/removed). There is no separate non-disableable flag or
special-cased core check for this plugin.

## Input source (`InputSources::Github`)

`poll!` is the entry point `PollRepositoryJob` calls per active,
non-archived repository. Each poll:

1. Lists open issues carrying the configured `trigger_label` (default
   `"syrus"`, configurable per-repository via `config_schema`'s
   `trigger_label` key) via `GithubClient.for(repository:, user:)`, plus
   closed issues with the same label (to close their Jobs — see below).
2. Preloads two caches for the whole batch before ingesting any single issue
   (`preload_ingest_caches`): the latest `Job` per issue number, and each
   issue body's parsed `Epic:` marker (`EpicMarkerParser`) — avoiding one
   query/parse per issue in a repo with many open issues.
3. Ingests each issue (`ingest`), gated by `IngestPolicy.evaluate` (an issue
   can be skipped — logged, not raised — for reasons unrelated to this
   plugin, e.g. duplicate/stale state).
4. Closes Jobs for issues that no longer carry the label / were closed
   upstream (`close_jobs_for_closed_issues!`) — scoped to open,
   PR-less, `issue`-kind Jobs matching the closed issue numbers, closed with
   `closure_reason: "issue_closed"`.
5. Calls `InputSources::PendingWorkWakeup.call(repository)` so any work
   blocked on new input can proceed immediately rather than waiting for the
   next poll tick.

Poll failures call `repository.mark_poll_failure!(e.message)` and re-raise;
success calls `repository.mark_poll_success!`. `dedup_key(issue)` is the
issue number as a string — the durable `external_ref` Jobs are matched
against on subsequent polls.

**Epic markers vs. plain issues.** `ingest` first checks
`marker_for(issue)` (an `Epic:`/`Epic: #<n>` line — see the root CLAUDE.md's
"Syrus Epic issue markers are body-only" convention: only a standalone body
line counts, never the title). `:epic_declaration` creates/finds an `Epic`
by its GitHub issue URL. `:child_of_epic` resolves the referenced Epic (or,
if it doesn't exist yet, files the Job with `triaging_reason:
"pending_epic_ref"` and a `pending_epic_reference` payload so a later poll —
once the Epic issue itself has been ingested — can attach it). Neither path
runs the plain-issue flow below.

**Plain issue ingestion.** For a genuinely new issue with no prior Job: if
the issue already has a linked open PR (`linked_open_pr_for_issue`), the Job
is created pre-closed with `closure_reason: "preempted"` and
`external_pr_number` set — Syrus never opens a second, competing PR for work
someone already did by hand. Otherwise a normal Job is created
(`initial_state_for_issue`, which special-cases a Syrus-recognized GitHub
`login` on the issue author via `Job.initial_state_for_creator`),
`skip_prepare` is set from the `syrus-skip-prepare` label, and — if the
issue body references image URLs — `IngestIssueImagesJob` is enqueued
(`enqueue_issue_image_ingest`). If a Job for this issue number **already
exists**, `ingest` only syncs the `skip_prepare` label state onto it
(`sync_issue_label_state!`) and, if a newly-observed linked external PR
number differs from what's stored, preempt-attaches to it — cancelling and
closing the prior Job if it's still open with no PR and no active Run.

## Source-control provider (`SourceControl::GithubOperations`)

Deliberately thin at the extension-point boundary:
`available_for?(repository)` is true whenever the repository's slug contains
a `/` (i.e., looks like `owner/name`); `client_for(repository:, user:)`
delegates straight to `GithubClient.for`. The actual PR/branch/merge/check
behavior other workflows call — opening PRs, landing, rebasing, reading
check state — lives in core's `GithubClient` and the workflow Step handlers
that call it, not in this thin plugin adapter. `input_source` and
`source_control_provider` are deliberately separate extension points
(plugins/README.md): a plugin can poll for work without owning PR
operations, or own PR operations without being a poll source. GitHub is
currently the only plugin providing both.

## Repo page tab and admin page

`GithubSource::RepoPageTabs` contributes a **GitHub Issues** tab
(`github_source/RepositoryIssues`, order `2`) on the repository detail page,
hidden entirely in `AppSetting.simple?` mode (a non-technical operator
tracks features, not the raw issue tracker) and when no repository is given.
The tab's backing controller
(`Api::V1::App::RepositoryIssuesController`) exposes list/comment/close/
delegate (add the trigger label)/bulk actions — the same operations
available from a Job's GitHub issue view, surfaced repository-wide.

`GithubSource::AdminPages` contributes **GitHub API Usage**
(`/admin/github_api_usage`, group `observability`, order `42`), backed by
`GithubSource::ApiUsagePayload`. That payload reads `GithubApiUsageRollup`
rows (bucketed request/rate-limit counters Syrus already records per GitHub
call) over a `?hours=` window (default 24h, capped at 168h/one week) and
returns aggregate totals, a per-operation/resource breakdown, a
per-repository breakdown, and the most recent 25 buckets that actually hit a
rate limit (`rate_limited_count > 0`) — this is diagnostic-only; it does not
throttle or influence live polling.

## What's not here

This plugin does not itself implement PR opening, landing, rebasing, or
check-state reads — those live in core service objects (`GithubClient` and
friends) that `SourceControl::GithubOperations#client_for` simply exposes.
Future source-control plugins (a hypothetical GitLab/Bitbucket integration)
would follow the same `input_source`/`source_control_provider` extension
points this plugin uses, per `plugins/README.md`.
