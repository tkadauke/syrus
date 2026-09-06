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

Once the integration branch is assembled, `merge_train_build` immediately pushes it to the repository and records it as the workflow's required workspace branch. Workflow workspaces live on each worker's local disk, but every Run is picked up by whichever worker is free, so a train routinely continues on a machine that has no copy of the workspace and re-clones. Publishing the branch means that re-clone can check out the branch the train is actually about to land; recording it means `WorkflowWorkspace` refuses to substitute anything else. Without both, the re-clone fell back to a single member's branch, and every later step — graders, `landing_fix`, and finally the land push — silently operated on that member branch while reporting on the train.

The published branch is disposable bookkeeping: `merge_train_land` deletes it after a successful landing, and a train that fails or is cancelled deletes it too. CI is unaffected because the repository's workflows build only `main` and pull requests, and the branch name is unique per train.

## Reconciliation phase

After building the integration branch, Syrus runs `merge_train_reconcile` on the recorded integration SHA before prepare, graders, coverage, and landing. This invokes the configured agent provider against the combined member work to inspect for cross-Job inconsistencies. If no reconciliation work is needed, no diff is treated as success. If focused reconciliation edits are needed, Syrus commits them onto the integration branch and updates the train's integration SHA.

If Syrus cannot check out the recorded integration SHA for reconciliation, the train fails with a rebuild-required classification instead of reconciling one arbitrary member branch.

Operator-facing states:
- **No-op reconciliation** — the train reports that reconciliation completed with no code changes and continues to graders.
- **Reconciliation commits** — the train reports that the agent committed focused integration fixes; those commits stay on the integration branch and must pass the normal gates before landing.
- **Reconciliation failure** — the train fails inside the merge-train workflow. Operators should inspect the failed `merge_train_reconcile` run and retry the merge train after addressing the cause; they should not create a standalone reconciliation Job for current Epics.

## Grader validation

Syrus then runs the required grader suite on the integration branch (same as `auto_merge`: `retry_until(graders, repair: landing_fix)`). Merge-train validation is pass/fail only and does not run `coverage_analyze`. If graders fail, the `landing_fix` agent repairs the integration branch, and graders re-run up to `grade_max_iterations` times.

## Land phase

`merge_train_land`:
1. Pushes the integration branch to GitHub.
2. Merges the integration PR into the base branch via the GitHub API. The resulting merge commit is created by GitHub, not locally, so Syrus fetches the base branch again before verifying members — otherwise the very next step would be checking ancestry against a commit the workspace has never seen.
3. For each member, verifies that its rebased commits (recorded during the build phase as `LandedCommit` rows) are actually reachable from the merged SHA before touching it. A member that verifies is commented on, its PR closed with a note that it was included in the train, and its Job closed `pr_merged` with the merge SHA recorded as `landed_sha`. A member that does **not** verify — for example a stale `MergeTrainMember` carried over from an earlier failed/rebuilt train whose branch was never actually rebased into *this* train's integration branch — is left open (PR untouched, branch not deleted) and routed through the normal landing-failure path instead of being closed against a landing it was never part of.

   Verification distinguishes "git can't answer the question" from "git answered no": a genuinely unreachable commit fails the member, but a SHA missing from the local object database (even after the extra fetch above — a `fatal: Not a valid commit name`/`Not a valid object name` error) is not proof the member didn't land. In that case Syrus instead trusts the member's own `LandedCommit` row when it was written by *this* workflow's own build phase moments earlier — the same positive-evidence standard `MergeTrainFailureHandler` uses for the failure path below — and only fails the member when no such recent evidence exists. This prevents a workspace-local gap (e.g. a Step's Run resuming on a different worker's disk) from reporting a successful integration merge as a failed member reconciliation.

   `bin/rails "syrus:repair_merge_train_member_reconciliation[owner/repo]"` (optionally scoped with `TRAIN_IDS=1,2`, and previewed with `DRY_RUN=true`) is the one-off repair for `MergeTrainMember` rows a past instance of this bug already left `failed` under a train that otherwise reached `state: "succeeded"`: it re-closes each member's Job `pr_merged` only when that member has its own recorded `LandedCommit` for the train, and never touches a train that never landed or a member with no such evidence.

If the base branch advances between build and land (GitHub returns a
base-moved error), Syrus inserts a `merge_train_rebase` →
`merge_train_agent_rebase` → re-grade → `merge_train_land_after_rebase`
recovery chain dynamically. `merge_train_rebase` first tries a deterministic
rebase of the integration branch onto the moved base. When that rebase is
clean, Syrus skips `merge_train_agent_rebase`; when it conflicts, the agentic
step resolves and completes the in-progress rebase before the train re-runs
landing graders.

While a merge train is active, Syrus suppresses new `rebase`, `stack_rebase`,
and ordinary Job workflows for child Jobs in the Epic. Those workflows resume
only after the train succeeds, fails, or is cancelled. If a race still creates
overlapping active work, the reconciler cancels the conflicting newer workflow
and keeps the older Epic-wide workflow running.

## Failure behavior

If the train fails at any phase, `MergeTrainFailureHandler` does **not** blanket-revert every member — reverting a member requires positive evidence its work did not land, not just "the workflow step failed":
- Members with no evidence their commits are on base go through `LandingFailureHandler`, which reverts them out of `landing`: transient blockers defer them back to `approved` (auto-retried once the blocker clears), while genuine failures fail them to `implemented`, clearing approval and requiring an operator to re-approve.
- A member whose commits are already verifiably on base when the train fails — e.g. GitHub reported the integration merge before a crash partway through closing member PRs — is instead completed retroactively: closed `pr_merged` with the landed SHA recorded, the same as the happy path. Its PR/branch may still need manual GitHub cleanup since the usual comment/close/delete-branch steps did not get to run for it.
- A 30-minute retry cooldown prevents the landing queue from immediately re-attempting an unrepaired integration conflict.
- Transient landing-start blockers, such as dependency readiness or admission pressure, do not use that failed-train cooldown. Once the blocker clears, the approved Epic children re-enter the landing queue and Syrus can dispatch a fresh train automatically.
- After the cooldown, `LandingQueueProcessor` can assemble a new train.

Operators can also manually retry the train from the Epic detail page.

## Size limit

`AppSetting.merge_train_max_size` (default: 20) caps the train size. Epics with more open approved Jobs than this limit require either splitting the Epic or increasing the limit.

## Same-Epic dependency satisfaction

Within an Epic, a child Job's dependency on a sibling is considered satisfied once the sibling is `approved` or `landing` (not just after it merges). This allows the full stack to flow into the landing queue together rather than waiting for sequential merges.
