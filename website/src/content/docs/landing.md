---
title: Landing Code
description: How Syrus moves approved Jobs, Epics, and bundles from PRs into a repository branch.
---

# Landing Code

Landing is the part of Syrus where automation stops being speculative. The
implementation exists, a reviewer has approved it, and Syrus is responsible
for moving it into the target branch without losing safety signals.

## Single Job Landing

Approved Jobs enter the landing queue. When a Job reaches the front of the
queue, Syrus creates an auto-merge workflow that:

1. checks whether the PR is still mergeable,
2. rebases or dispatches a rebase workflow if the branch is stale,
3. prepares the workspace,
4. runs the landing-phase graders,
5. asks the agent for a focused landing fix if those graders fail,
6. pushes any final repair commits, and
7. merges the PR only after re-checking approval, branch state, and repository
   policy.

The merge step treats transient GitHub states as deferrals rather than final
failures. For example, if GitHub is still recomputing mergeability after a
push, Syrus waits briefly and retries instead of throwing away a green grader
run.

The experimental early Epic dependency-execution feature changes when a
same-repository dependent Epic may begin implementation, not when it may land.
Its children may be approved while an upstream Epic is unfinished, but they
remain outside the merge train until every upstream Epic has completed
successfully. Syrus rechecks that strict boundary during dispatch and assembly
so stale queue snapshots and restarts cannot bypass landing order.

## Epic Merge Trains

When an Epic's open child Jobs are all approved, Syrus lands the Epic as one
unit. It builds an integration branch by applying the child PR branches in
dependency order, runs the landing graders once on the combined tree, lets the
agent reconcile integration-only conflicts if needed, then merges the
integration branch.

The goal is atomicity: either the whole Epic lands together, or no child lands.
This keeps a feature from being half-present on the base branch.

Because the Epic lands as one unit, Syrus refuses a dependency that would make
the Epic wait for itself through an outside Job: for example, one child
depending on an outside Job that depends on another child. Neither the Epic nor
that Job could ever land, so the error names both, and the dependency is not
saved.

The integration branch is pushed to your repository as soon as it is built, so
the rest of the landing attempt can continue on any worker. It is temporary
bookkeeping under a `syrus/` name unique to that train, and Syrus deletes it
once the train lands, fails, or is cancelled, except when the failure policy
keeps a stale branch briefly so a replacement train can reuse its fixes.
If inline deletion is interrupted, recurring reconciliation retries terminal
merge-train and job-bundle branches in bounded batches. Before deleting, Syrus
checks that the ref is still Syrus-owned, is not used by an open pull request
or active work, and still points at the recorded integration SHA.

When the instance is configured to keep merge-train fixes, a stale failed train
can rebuild from the current base while replaying repair commits from the
previous integration branch. Syrus only does this when the member set is
unchanged and the old commits can be cherry-picked cleanly; otherwise it falls
back to the rebuilt member work and re-runs the normal landing checks.

## Job Bundles

Job bundles use the same idea for independent approved Jobs that are safe to
land together. Syrus assembles a landing unit, validates the combined result,
and lands the bundle as one operation. Bundles are intentionally conservative:
they should reduce repeated grader work without hiding unrelated review or
ownership boundaries. A bundle only ever contains Jobs with the same priority,
the same owner, and the same execution requirements, so a macOS Job never
shares a bundle with Linux Jobs.

## Stopping a Landing Attempt

While a Job is actively landing -- on its own or as part of an Epic merge
train -- its Job detail page shows a **Stop Landing** button. Anyone who could
otherwise act on the Job (its owner, an admin, or a repository member with
write access) can use it.

Stop Landing cancels the in-progress landing workflow and moves the Job back
to implemented, clearing its approval. That's intentional: stopping a landing
attempt is a deliberate decision, so Syrus asks for a fresh approval before it
tries again rather than silently re-queuing. For an Epic merge train, stopping
it reverts every member Job the same way any other train failure does. Unlike
the general Cancel button, Stop Landing does not close the Job -- the PR and
branch stay in place, ready to re-approve.

## Emergency Land

Emergency land is separate from the normal landing queue. When enabled with the
`emergency_land` feature flag, a repository admin can explicitly confirm an
incident-only submission of the active clean, committed Coding Mode checkout,
or an eligible existing Job branch. Syrus captures and verifies the exact pushed
commit, creates audit Job metadata when needed, skips graders, reviews,
admission control, and normal workflow worker dispatch, then opens and merges a normal GitHub PR.
GitHub branch protection and mergeability checks remain in force.
When opening the pull request, Syrus retries HTTP 500, 502, 503, and 504
responses up to four total attempts with jittered exponential backoff capped at
eight seconds. Before each repeated create request, it looks for a matching open
pull request and adopts it if GitHub created it despite the earlier error. Other
errors are not retried. If landing fails after a direct checkout capture,
Syrus marks the newly created audit Job failed so it cannot be approved or
appear as awaiting approval. The immutable branch, captured source commit, and
any pull request already opened remain attached to that Job. A new
operator-confirmed emergency-land attempt targeting the Job reuses those
artifacts instead of recapturing the checkout or creating another Job. A
failed attempt targeting an existing Job leaves that Job's lifecycle state
unchanged.
For a newly opened PR, Syrus gives GitHub up to about 30 seconds to finish
computing mergeability. A real conflict stops immediately; if mergeability is
still unknown, the confirmation fails with a retryable message rather than
claiming the branch conflicts. Retrying after any failed confirmation creates
a fresh confirmation.
The merge itself waits for any landing that is merging into the same branch at
that moment, so it can never land between that landing's base check and its
merge; if the branch stays busy for about ten minutes, the confirmation fails
with a retryable message.
The confirmation remains in progress until the merge succeeds; capture or
landing failures are recorded as failed confirmations instead of appearing applied.

Job detail shows a captured source commit and comparison link even when the
direct capture has no Workflow or Run diff, including after a landing failure.
Every successful emergency land is additionally auditable: the Job closes with
`closure_reason: "emergency_landed"` and records the confirming operator,
permission tier, timestamp, source SHA, and skipped controls. Admins can find
past successful uses through Job filters or the admin Jobs API with
`closure_reason=emergency_landed`.

## What Can Block Landing

Common blockers include:

- unsatisfied Job or Epic dependencies, including dependencies that wait for a
  configured deployment stage on an upstream Job,
- an unmergeable PR branch,
- pending or failed required PR checks,
- another epic-wide workflow already active for the same Epic,
- admission-control or provider-availability pauses,
- a manual pause,
- a PR that needs a rebase while every rebase slot of the repository is in
  use (shown as waiting for a rebase slot),
- a paused rebase for a merge train's stack, which an operator must resume or
  cancel before the train starts,
- a runaway-protected Job whose last merge train failed after its approval,
  until an operator re-approves it,
- repository policy that pauses landing while main-branch health is broken.

The dashboard's landing queue explains the active queue status. The Job detail
page shows the latest workflow and, when admin debugging is enabled, the Work
Intent and Work Unit that Syrus is using internally to schedule the attempt.

## Landing Concurrency

By default a repository lands one unit at a time. The repository setting
`landing_concurrency` (1 to 5, default 1, next to the "Trust clean rebases"
option in the repository form) lets up to that many landing units, whether a
single Job, a job bundle, or an Epic merge train, validate at once. Only the
final merge is serialized, so whichever unit is ready first merges first and
the others rebase onto the moved base and continue. Each running unit holds
one landing lane; a unit that fails its graders holds only its own lane while
the others keep landing. With the default of 1, landing works exactly as it
always has.

With the instance-wide `landing_lanes` Labs feature enabled, Syrus exposes these lanes to authenticated clients through
`GET /api/v1/app/landing_lanes`. The response includes configured and busy
lane counts, the ordered approved backlog, empty slots, and each visible
landing unit's Jobs, workflow phase, graders, progress, and best-case time
remaining. Lanes are reported per landing branch: `lanes` are the default
branch's lanes, and a branch that a delivery track lands to has its own lanes
under `additional_branches`, listed only while it has an active landing. The
estimate weights graders by their recent successful runtimes
and assumes all remaining work passes on its current attempt, so it is always
identified as `best_case`. Clients receive `landing_lanes.updated` app events
when landing workflow or grader state changes and can refetch the payload
without polling.

The feature is off by default during rollout and gates only the dashboard strip, full landing-lanes page, and API payload. Turning it off does not change the existing landing queue summary, configured concurrency, or landing behavior.

## Reusing Green Results

Landing can reuse a previous green validation when the proof still matches the
branch Syrus is about to land. Reuse may be based on the exact commit SHA, an
identical Git tree, or a clean rebase if the repository opts into trusting
clean rebases.

This is a throughput optimization, not a shortcut around safety. Syrus records
why it reused or re-ran graders so operators can understand what happened.

## Failed Landing Attempts

Some failures are retryable and should stay in the queue. Others need operator
attention: a real merge conflict, repeated grader failure, exhausted provider
quota, or a policy decision that Syrus cannot make safely.

When a landing attempt fails after a successful implementation, Syrus should
preserve the useful implementation state and retry the smallest safe unit of
work. If a workspace is gone, checkpoint refs let Syrus recover agent-produced
commits without restarting the entire Job from scratch.
