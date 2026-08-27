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

## Epic Merge Trains

When an Epic's open child Jobs are all approved, Syrus lands the Epic as one
unit. It builds an integration branch by applying the child PR branches in
dependency order, runs the landing graders once on the combined tree, lets the
agent reconcile integration-only conflicts if needed, then merges the
integration branch.

The goal is atomicity: either the whole Epic lands together, or no child lands.
This keeps a feature from being half-present on the base branch.

## Job Bundles

Job bundles use the same idea for independent approved Jobs that are safe to
land together. Syrus assembles a landing unit, validates the combined result,
and lands the bundle as one operation. Bundles are intentionally conservative:
they should reduce repeated grader work without hiding unrelated review or
ownership boundaries.

## What Can Block Landing

Common blockers include:

- unsatisfied Job or Epic dependencies,
- an unmergeable PR branch,
- pending or failed required PR checks,
- another epic-wide workflow already active for the same Epic,
- admission-control or provider-availability pauses,
- a manual pause,
- repository policy that pauses landing while main-branch health is broken.

The dashboard's landing queue explains the active queue status. The Job detail
page shows the latest workflow and, when admin debugging is enabled, the Work
Intent and Work Unit that Syrus is using internally to schedule the attempt.

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
