# Epic Merge Trains

The merge train feature lands all approved child Jobs of an Epic atomically through a single integration branch, rather than one-by-one. This prevents ordering problems and partial-stack merges when PRs in an Epic have dependencies on each other.

## Enabling merge trains

```ruby
AppSetting.current.update!(merge_train_enabled: true)
```

When disabled (default), approved Epic child Jobs land individually via `auto_merge` as soon as they are approved.

## When a merge train fires

1. An operator approves the last open child Job in an Epic.
2. `LandingQueueProcessor` confirms the Epic has released its children for execution and all open sibling Jobs are `approved`.
3. Syrus dispatches a `merge_train` workflow on the Epic.
4. All member Jobs move to `landing` state until the train succeeds or fails.

While waiting for siblings, Jobs show a blocked reason: "waiting for Epic merge-train."
If the Epic itself is still blocked by an upstream Epic dependency, child Jobs show "waiting for Epic to release" and no merge train is dispatched.

Merge trains are Epic-wide workflows. Only one Epic-wide workflow may be active
for an Epic at a time, and an active Epic-wide workflow blocks ordinary Job
workflows for every child Job in the Epic. This prevents branch-rewriting stack
maintenance and integration-branch landing from racing each other.

## Assembly requirements

`merge_train_assemble` validates:
- The Epic has released its children for execution.
- Every open child Job in the Epic is in `approved` state.
- The member count does not exceed `AppSetting.merge_train_max_size` (default: 20).

If either check fails, the train is cancelled and member Jobs revert to `approved`.

## Build phase

`merge_train_build` creates a fresh integration branch starting from the base branch tip. It then rebases each member branch onto the growing integration tip in dependency order (respecting `Depends-on:` lines between child Jobs). Legacy nonlinear Epics (an Epic whose `epic_dependency_policy` is the now-unselectable `"nonlinear"` value, or whose `JobDependency` graph predates the unconditional same-Epic linear-chain enforcement) are handled the same way: a root with multiple approved leaves produces one integration branch containing every member branch before reconciliation runs. No new fan-in/fan-out structure can be created going forward — see [Epic Dependency Policy](epic_dependency_policy.md) — but the build phase keeps serving whatever structure already exists on older Epics unmodified.

For each member branch:
- Syrus first tries a deterministic `git rebase`. If clean, it advances the integration tip.
- On conflict, the agentic `merge_train_build` step hands the in-progress rebase to the agent, which must resolve conflicts and run `git rebase --continue`. Syrus verifies completion by end-state (clean worktree, integration branch is an ancestor) rather than by rebase-internal refs.
- If the agent cannot complete that conflict resolution, the run is classified as `merge_train_rebase_conflict` so operators see an actionable merge-train conflict instead of a generic git failure.

Branch refs are fetched through the repository's authenticated GitHub URL so private branches work under App or PAT credentials.

## Reconciliation phase

After building the integration branch, Syrus runs `merge_train_reconcile` on the recorded integration SHA before prepare, graders, coverage, and landing. This invokes the configured agent provider against the combined member work to inspect for cross-Job inconsistencies. If no reconciliation work is needed, no diff is treated as success. If focused reconciliation edits are needed, Syrus commits them onto the integration branch and updates the train's integration SHA.

If Syrus cannot check out the recorded integration SHA for reconciliation, the train fails with a rebuild-required classification instead of reconciling one arbitrary member branch.

Operator-facing states:
- **No-op reconciliation** — the train reports that reconciliation completed with no code changes and continues to graders.
- **Reconciliation commits** — the train reports that the agent committed focused integration fixes; those commits stay on the integration branch and must pass the normal gates before landing.
- **Reconciliation failure** — the train fails inside the merge-train workflow. Operators should inspect the failed `merge_train_reconcile` run and retry the merge train after addressing the cause; they should not create a standalone reconciliation Job for current Epics.

## Grader validation

Syrus then runs the required grader suite on the integration branch (same as `auto_merge`: `retry_until(graders, repair: landing_fix)`), using each grader's `fast` command when configured. Merge-train validation is pass/fail only and does not run `coverage_analyze`. If graders fail, the `landing_fix` agent repairs the integration branch, and graders re-run up to `grade_max_iterations` times.

## Land phase

`merge_train_land`:
1. Pushes the integration branch to GitHub.
2. Merges the integration PR into the base branch via the GitHub API.
3. Comments on and closes each member PR with a note that it was included in the train.

If the base branch advances between build and land (GitHub returns a base-moved error), Syrus inserts a `merge_train_rebase` → re-grade → `merge_train_land_after_rebase` recovery chain dynamically.

While a merge train is active, Syrus suppresses new `rebase`, `stack_rebase`,
and ordinary Job workflows for child Jobs in the Epic. Those workflows resume
only after the train succeeds, fails, or is cancelled. If a race still creates
overlapping active work, the reconciler cancels the conflicting newer workflow
and keeps the older Epic-wide workflow running.

## Failure behavior

If the train fails at any phase:
- All member Jobs revert from `landing` back to `approved`.
- A 30-minute retry cooldown prevents the landing queue from immediately re-attempting an unrepaired integration conflict.
- Transient landing-start blockers, such as dependency readiness or admission pressure, do not use that failed-train cooldown. Once the blocker clears, the approved Epic children re-enter the landing queue and Syrus can dispatch a fresh train automatically.
- After the cooldown, `LandingQueueProcessor` can assemble a new train.

Operators can also manually retry the train from the Epic detail page.

## Size limit

`AppSetting.merge_train_max_size` (default: 20) caps the train size. Epics with more open approved Jobs than this limit require either splitting the Epic or increasing the limit.

## Same-Epic dependency satisfaction

Within an Epic, a child Job's dependency on a sibling is considered satisfied once the sibling is `approved` or `landing` (not just after it merges). This allows the full stack to flow into the landing queue together rather than waiting for sequential merges.
