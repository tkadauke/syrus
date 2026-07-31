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

## Assembly requirements

`merge_train_assemble` validates:
- The Epic has released its children for execution.
- Every open child Job in the Epic is in `approved` state.
- The member count does not exceed `AppSetting.merge_train_max_size` (default: 20).

If either check fails, the train is cancelled and member Jobs revert to `approved`.

## Build phase

`merge_train_build` creates a fresh integration branch starting from the base branch tip. It then rebases each member branch onto the growing integration tip in dependency order (respecting `Depends-on:` lines between child Jobs).

For each member branch:
- Syrus first tries a deterministic `git rebase`. If clean, it advances the integration tip.
- On conflict, the agentic `merge_train_build` step hands the in-progress rebase to the agent, which must resolve conflicts and run `git rebase --continue`. Syrus verifies completion by end-state (clean worktree, integration branch is an ancestor) rather than by rebase-internal refs.

Branch refs are fetched through the repository's authenticated GitHub URL so private branches work under App or PAT credentials.

## Grader validation

After building the integration branch, Syrus runs `merge_train_reconcile` on it before prepare, graders, coverage, and landing. This invokes the configured agent provider against the integration branch to inspect the combined member work for cross-Job inconsistencies. If no reconciliation work is needed, no diff is treated as success. If focused reconciliation edits are needed, Syrus commits them onto the integration branch and updates the train's integration SHA.

Syrus then runs the full grader suite on the integration branch (same as `auto_merge`: `retry_until(graders, repair: landing_fix)`). If graders fail, the `landing_fix` agent repairs the integration branch, and graders re-run up to `grade_max_iterations` times.

## Land phase

`merge_train_land`:
1. Pushes the integration branch to GitHub.
2. Merges the integration PR into the base branch via the GitHub API.
3. Comments on and closes each member PR with a note that it was included in the train.

If the base branch advances between build and land (GitHub returns a base-moved error), Syrus inserts a `merge_train_rebase` → re-grade → `merge_train_land_after_rebase` recovery chain dynamically.

## Failure behavior

If the train fails at any phase:
- All member Jobs revert from `landing` back to `approved`.
- A 30-minute retry cooldown prevents the landing queue from immediately re-attempting an unrepaired integration conflict.
- After the cooldown, `LandingQueueProcessor` can assemble a new train.

Operators can also manually retry the train from the Epic detail page.

## Size limit

`AppSetting.merge_train_max_size` (default: 20) caps the train size. Epics with more open approved Jobs than this limit require either splitting the Epic or increasing the limit.

## Same-Epic dependency satisfaction

Within an Epic, a child Job's dependency on a sibling is considered satisfied once the sibling is `approved` or `landing` (not just after it merges). This allows the full stack to flow into the landing queue together rather than waiting for sequential merges.
