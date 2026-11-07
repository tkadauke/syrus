# Scheduling and polling

Syrus has no inbound GitHub webhook path. Recurring Solid Queue jobs discover
external changes and convert them into durable domain work. The schedule is
declared in `config/recurring.yml`; queue ownership is documented in
[Deployment](../operations/deployment.md).

## Issue ingestion

`PollAllRepositoriesJob` fans out one `PollRepositoryJob` per active
repository. The poller lists issues carrying the configured trigger label,
ignores already-ingested issue identities, and creates a `Job` using the
repository's credential mode. Model callbacks create the initial Workflow and
first Run; pollers do not invoke agents directly. Syrus-owned HTML markers are
parsed conservatively so arbitrary issue prose cannot impersonate internal
state. See `spec/jobs/poll_repository_job_spec.rb`.

## Pull-request and chat feedback

`PollAllPullRequestsJob` fans out checks for implemented Jobs. Review comments,
PR issue comments, requested changes, and configured CI failures are normalized
and deduplicated with durable watermarks before a follow-up Workflow is
requested. Feedback retains the existing Job, user, credential mode, branch,
and pull request. Chat handoffs follow the same ownership rules. See
`app/jobs/poll_pull_request_job.rb`, `app/services/github_comment_watermark.rb`,
and their focused specs.

## Rebase and landing observation

Landing pollers observe mergeability and remote-head changes. Rebase workflows
record the SHA they observed and use force-with-lease. Merge-train and
auto-merge work launches through registered WorkDefinitions and landing-slot
locks. Reconciliation repairs WorkUnit/WorkIntent ownership before redispatch.
Relevant code lives in `app/jobs/poll_*merge*.rb`,
`app/services/landing_queue/`, and `app/services/work_definitions/`.

## Scheduled work

The scheduled-tasks plugin owns persisted recurring prompts and parsing; core
does not hard-code its Job kind. A due fire creates one durable occurrence and
advances its watermark transactionally. Scheduled chat messages use the same
principle but deliver to a ChatSession. Operator behavior is documented under
`plugins/scheduled_tasks/docs/`; implementation and specs stay in that plugin.

## External pull requests and insights

`PollAllExternalOpenPrsJob` ingests opt-in pull requests opened outside Syrus
as `external_pr` Jobs, without pretending Syrus created their branches. Agent
insight scheduling creates infrastructure analysis work through its registered
kind and stores suggestions durably; it is not ordinary issue ingestion.

## Stale-run recovery

Heartbeats and worker ownership distinguish a slow Run from an abandoned one.
The stale-run reaper checks leases and worker state before transitions, while
`WorkEngine::Reconciler` repairs mismatched ownership. Operators use
[Workflow recovery](../operations/workflow-recovery.md), never direct database
state edits. See `app/jobs/reap_stale_runs_job.rb` and
`app/services/work_engine/reconciler.rb`.
