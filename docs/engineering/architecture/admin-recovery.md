# Admin Recovery Architecture

This page describes the persistence, queue, and frontend mechanics behind
admin recovery. Operator-facing tool semantics remain in the
[searchable recovery guide](../../../config/syrus_docs/admin_recovery.md), and
deployed process restart procedures live in the [operations runbook](../operations/admin-recovery.md).

## Dead worker queues and affinity repair

Queued Runs on an explicit `worker-*` or storage-affinity `resume-*` queue are
reported after a five-minute grace period when no live worker consumes that
queue. The detector records the Job, Workflow, Run, queue, age, claim state,
Run state, and whether workflow affinity remains. Shared queues such as `runs`
are never repair candidates, and a dead explicit queue is excluded until
current routing has compatible live replacement capacity.

Bulk repair requests produce one grouped confirmation with the affected Run
and Workflow ids and dead queues. Confirmation locks and revalidates each Run
independently: claimed work is never disturbed, Runs that moved on become
no-ops, stale unclaimed queue rows are removed, and the Run is re-enqueued
through current capability and admission routing. Terminal Runs are not repair
candidates.

On confirmation, queue-affinity repair locks the Run, Workflow, and matching
unclaimed Solid Queue `RunJob` rows. It refuses any claimed row. Otherwise it
deletes matching ready, scheduled, blocked, and failed executions, clears
`worker_hostname` and `worker_storage_key`, and force re-enqueues the Run.
Keeping that order in one transaction prevents old resume-queue delivery from
re-stamping stale affinity.

Repair audit records contain bounded snapshot references (byte count and
SHA-256 digest) rather than complete snapshots in `admin_actions.params`.
Because Solid Queue can use a separate database, repair first commits a compact
intent on the primary database. Queue mutation is idempotent and revalidated;
final audit evidence and the confirmation outcome then commit together. If
final evidence cannot be persisted, the durable intent remains and the action
reports `partial` rather than falsely reporting `failed`.

## Successful closure internals

Confirming `close_job_successfully` cancels active execution records only to
make the close coherent, preserves historical Workflow and Run rows, and calls
`Job#close_with_reason!`. If the Job tracks a PR and credentials are available,
Syrus posts the optional comment and closes the PR. A GitHub cleanup failure
does not roll back the successful local closure; the outcome reports partial
PR cleanup instead.

## Stale Run reconciliation

The admin stale-run reap action delegates to the unified work-engine
reconciler. It handles stale Runs, orphaned queued Runs, queued Workflows with
no first Run, terminal orphan Workflows, and missed worker-death auto-retries.
It also cancels queued automatic retry Workflows when their failed source has
already been superseded by a newer successful Workflow.

## Admin mutation feedback

Admin pages surface mutation failures inline and refresh affected data so an
operator does not continue acting on a stale row. This applies to maintenance
tasks and discovery, user role and scheduling changes, operator-console
toggles, and Work Unit debug visibility.

The Processes list and detail page poll while a process is active. Sending
`SIGKILL` requires confirmation; if the process finishes first, the conflict
is shown and process data is refreshed. The GitHub App installations page
shows queued-sync acknowledgement and polls briefly after refresh so the latest
sync status replaces pre-sync data.

## Planned-execution override internals

The placement override operation validates the complete Job profile and
requires triage/backlog state or an initial Workflow whose Runs have not
started and whose mutable workspace does not exist. Confirmation rechecks the
Job revision and safety conditions under row locks before atomically updating
the Job and queued initial Workflow.

Every successful change records actor, reason, provenance, timestamp, and the
complete previous and replacement placement. Queue deliveries are replaced
only after the placement transaction commits. If replacement enqueue fails,
Syrus requests WorkEngine reconciliation; the recurring stale-work reconciler
remains the durable fallback.
