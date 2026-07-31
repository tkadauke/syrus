# Landing Queue

The landing queue manages the flow from "approved" to "merged." Once a Job is approved, Syrus queues it for landing via the `auto_merge` workflow (or `merge_train` for Epics with merge trains enabled).

## Approval and landing

When an operator approves a Job:

1. The Job transitions to `approved`.
2. `LandingQueueProcessor.try_land!` evaluates whether the Job can proceed immediately or must wait.
3. If ready, Syrus dispatches an `auto_merge` workflow and moves the Job to `landing`.

Jobs wait in `approved` when:
- A same-repo Job is already landing (serialized per repo by default).
- The Job is part of an Epic with `merge_train_enabled` and siblings aren't yet approved.
- A dependency Job hasn't closed successfully.
- The repository's main branch health is `broken` and Syrus has paused repository landing for repair.

`inconclusive` main branch health is warning-only. Syrus shows the main-health warning surfaces and notifications, but it does not hold queued workflows or landing queue entries solely because the signal is inconclusive.

## auto_merge workflow

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → coverage_analyze? → push → auto_merge`

### mergeability_preflight

Refreshes GitHub's mergeability status for the PR. If GitHub is still computing (`mergeable: null`), waits briefly and retries. If the branch has conflicts, dispatches a `rebase` workflow and defers. If a prior landing validation is still valid for the current head/base pair, skips grader re-validation.

### Grader re-validation

Before merging, Syrus re-runs the full required grader suite on the exact PR branch being landed. If graders fail, `landing_fix` (an agentic repair step) attempts a fix, and graders re-run. This loop repeats up to `grade_max_iterations` times.

### push and auto_merge

After graders pass, Syrus pushes any repair commits and calls the GitHub merge API. The merge method (merge, squash, or rebase) is configured per-repository.

### Transient failures

If GitHub's merge API returns a transient error, the Job is deferred back to `approved` and retried. If GitHub returns 405 "PR can't be rebased," Syrus dispatches a `rebase` workflow instead of treating the attempt as terminal.

### After a successful merge

The Job transitions to `pr_merged`. If the merged PR was depended on by other Jobs, those dependencies are satisfied and their workflows unblocked.

## trust_clean_rebase_grade

When `Repository#trust_clean_rebase_grade` is enabled (off by default), a clean `rebase` workflow can carry forward a prior green landing validation to the new head/base pair. This allows `auto_merge` to skip re-running graders when the only change is a rebase onto the base branch.

Grade carry-forward is gated on the `LandingValidationCache` artifact matching the exact PR head SHA and base SHA being landed. It is never applied speculatively.

## LandingValidationCache

Stores the result of a successful required-grader run as a workflow artifact:

```json
{
  "required_graders_passed": true,
  "head_sha": "abc123",
  "base_sha": "def456",
  "base_ref": "main",
  "checked_at": "2026-07-13T10:00:00Z"
}
```

Later `auto_merge` or `merge_train` retries can skip re-validation when the artifact's `head_sha` matches the PR's current head.

## Dependency gating

A Job blocked on another Job will not enter the landing queue until the dependency closes with one of these reasons: `pr_merged`, `external_pr_merged`, `pr_approved`, or `no_changes`. Same-Epic dependencies are also satisfied once the upstream Job is `approved` or `landing`.

Implementation has a narrower, execution-only exception: a same-Epic child Job may start on an `implemented` parent once that parent has a materialized branch, PR, and head SHA, as long as stack parent selection is unambiguous. This does not satisfy the landing gate above.

Operators can add or remove manual dependencies from the Job detail page; admins can override the gate.

## No-changes resolution

If a PR is closed without merging but its branch has no unique patches left against the base, Syrus closes the Job as `no_changes` rather than `pr_closed`. `no_changes` counts as a successful resolution for dependency gates and landing queue wakeups.
