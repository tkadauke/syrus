# Landing Queue

The landing queue manages the flow from "approved" to "merged." Once a Job is approved, Syrus queues it for landing via the `auto_merge` workflow (or `merge_train` for Epics with merge trains enabled).

## Approval and landing

When an operator approves a Job:

1. The Job transitions to `approved`.
2. `LandingQueueProcessor.try_land!` evaluates whether the Job can proceed immediately or must wait.
3. If ready, Syrus dispatches an `auto_merge` workflow and moves the Job to `landing`.

Landing queue candidates are ordered by `Job#priority` first
(`urgent`, `high`, `medium`, `low`), then by the existing FIFO approval
order (`approved_at`, falling back to `updated_at`, then `id`) within the
same priority. Dependency prerequisites still sort before their dependents,
and Epic merge-train members stay grouped as one atomic landing unit.

When repository approval propagation is enabled, Syrus mirrors eligible Job
approvals as GitHub PR reviews. Jobs created with PAT credentials are skipped
because those PRs were opened as the user, and GitHub rejects self-approval.

Jobs wait in `approved` when:
- A same-repo Job is already landing (serialized per repo by default).
- The Job is part of an Epic with `merge_train_enabled` and siblings aren't yet approved.
- A dependency Job hasn't closed successfully.
- The repository's main branch health is `broken` and Syrus has paused repository landing for repair.

`inconclusive` main branch health is warning-only. Syrus shows the main-health warning surfaces and notifications, but it does not hold queued workflows or landing queue entries solely because the signal is inconclusive.

The dashboard's landing queue `Blocked reason` column first shows the per-Job
queue blocker recorded by `LandingQueueProcessor`. If that value is blank,
the dashboard falls back to merge-train and start-gate diagnostics for the
same landing unit, such as a queued merge train blocked by `urgent_job_active`,
an already-active merge train, or landing state drift where a Job is in
`landing` with no active workflow or train.

## auto_merge workflow

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge`

### mergeability_preflight

Refreshes GitHub's mergeability status for the PR. If GitHub is still computing (`mergeable: null`), waits briefly and retries. If the branch has conflicts, dispatches a `rebase` workflow and defers. If a prior landing validation is still valid for the current artifact, base, and grader configuration, skips grader re-validation and logs the reuse reason.

### Grader re-validation

Before merging, Syrus re-runs the full required grader suite on the exact PR branch being landed.

Landing throughput instrumentation is written to each Workflow's
`landing_throughput_metrics` artifact and surfaced in admin workflow debug
payloads. Validation decisions record whether landing graders were skipped or
rerun, the cache match type (`exact_head`, `same_tree`, or
`clean_rebase_carry_forward`), and the rejection reason when Syrus reruns
validation. Grader loop timing records the grader count, wall-clock duration,
summed individual durations, and whether required graders failed. Fanout-specific
cap and efficiency metrics are intentionally absent until parallel landing
grader fanout is designed and enabled separately.

If graders fail, `landing_fix` (an agentic repair step) attempts a fix, and graders re-run. This loop repeats up to `grade_max_iterations` times.

### push and auto_merge

After graders pass, Syrus pushes any repair commits and calls the GitHub merge API. The merge method (merge, squash, or rebase) is configured per-repository.

### Transient failures

If GitHub's merge API returns a transient error, the Job is deferred back to `approved` and retried. If GitHub returns 405 "PR can't be rebased," Syrus dispatches a `rebase` workflow instead of treating the attempt as terminal.

### After a successful merge

The Job transitions to `pr_merged`. If the merged PR was depended on by other Jobs, those dependencies are satisfied and their workflows unblocked.

## trust_clean_rebase_grade

When `Repository#trust_clean_rebase_grade` is enabled (off by default), a clean `rebase` workflow can carry forward a prior green landing validation to the new head/base pair. A clean `merge_train_rebase` recovery can do the same for a base-moved Epic integration branch. This allows later `auto_merge` or `merge_train` landing steps to skip re-running graders when the only change is a mechanical clean rebase onto the base branch.

Grade carry-forward records a fresh `LandingValidationCache` artifact for the post-rebase head, tree, base ref, base SHA, required-grader fingerprint, and changed-file fingerprint. It only carries forward from a successful required-grader validation, not from another carried validation, and both fingerprints must match the source validation. The grader fingerprint includes selection inputs such as `when_files_changed`, and the changed-file fingerprint catches a clean rebase that changes which file-glob-gated graders would run. Later reuse reports this as `clean_rebase_carry_forward` rather than as a normal exact-head hit. It is never applied speculatively.

## LandingValidationCache

Stores the result of a successful required-grader run as a workflow artifact:

```json
{
  "required_graders_passed": true,
  "head_sha": "abc123",
  "tree_sha": "tree789",
  "base_sha": "def456",
  "base_ref": "main",
  "grader_fingerprint": "grade-plan-sha256",
  "validation_source": "graders",
  "checked_at": "2026-07-13T10:00:00Z"
}
```

Later `auto_merge` or `merge_train` retries can skip re-validation when:

- `exact_head`: the artifact's `head_sha` matches the commit being landed.
- `clean_rebase_carry_forward`: a trusted clean rebase re-stamped the validation for the new head/base.
- `same_tree`: the commit SHA differs, but the Git tree SHA matches the validated tree.

All reuse requires the base ref/base SHA and required grader fingerprint to remain unchanged when those values are recorded. Stale validations older than seven days are rejected. Audit logs explain whether landing graders were skipped or rerun, including changed base, changed grader configuration, stale validation, and cache-miss reasons.

## Dependency gating

A Job blocked on another Job will not enter the landing queue until the dependency closes with one of these reasons: `pr_merged`, `external_pr_merged`, `pr_approved`, or `no_changes`. Same-Epic dependencies are also satisfied once the upstream Job is `approved` or `landing`.

If the prerequisite Job closes unsuccessfully, including `cancelled`, dependents remain blocked with `dependency_failed` until an operator removes or overrides the dependency. Syrus should not keep creating maintenance rebase workflows for a dependent while it is in this permanent dependency-failed state.

Implementation has a narrower, execution-only exception: a same-Epic child Job may start on an `implemented` parent once that parent has a materialized branch, PR, and head SHA, as long as stack parent selection is unambiguous. For approved same-Epic fan-in, Syrus may also create a prepared combined base branch and start the child there when all dependency PR branches merge cleanly. This does not satisfy the landing gate above.

Operators can add or remove manual dependencies from the Job detail page; admins can override the gate.

## No-changes resolution

If a PR is closed without merging but its branch has no unique patches left against the base, Syrus closes the Job as `no_changes` rather than `pr_closed`. `no_changes` counts as a successful resolution for dependency gates and landing queue wakeups.
