# Epic Merge Trains

Merge trains always land all approved child Jobs of an Epic atomically through
a single integration branch, rather than one-by-one. This core behavior
prevents ordering problems and partial-stack merges when PRs in an Epic have
dependencies on each other. Operators can tune the train's maximum size and
failure policy, but there is no global enable/disable switch.

## When a merge train fires

1. An operator approves the last open child Job in an Epic.
2. Syrus confirms all upstream Epic dependencies completed successfully and all open sibling Jobs are `approved`.
3. Syrus dispatches a `merge_train` workflow on the Epic.
4. All member Jobs move to `landing` state until the train succeeds or fails.

While waiting for siblings, Jobs show a blocked reason: "waiting for Epic merge-train."
An Epic released by the experimental early dependency-execution feature may
implement and collect approval while its upstream Epic is unfinished, but it
remains outside the merge train. The dispatcher checks strict Epic dependency
completion both before dispatch and again while holding the Epic lock; the
assemble step rechecks it once more before building. This keeps landing and
Epic completion in dependency order even across scheduler restarts or stale
queue snapshots.

Merge trains are Epic-wide workflows. Only one Epic-wide workflow may be active
for an Epic at a time, and an active Epic-wide workflow blocks ordinary Job
workflows for every child Job in the Epic. This prevents branch-rewriting stack
maintenance and integration-branch landing from racing each other.

## Assembly requirements

`merge_train_assemble` validates:
- Every upstream Epic dependency completed successfully.
- Every open child Job in the Epic is in `approved` state.

There is no size limit on an Epic train — see [Size limit](#size-limit).

If a check fails, the train is cancelled and member Jobs revert to `approved`.

## Build phase

Syrus creates a fresh integration branch from the current base and rebases each member onto it in dependency order. Clean rebases proceed automatically; conflicts are offered to an agent and reported as actionable merge-train conflicts if unresolved. Private branches use the repository's configured credentials.

The assembled branch is published so later Runs on another worker can resume the exact integration. The branch is disposable and is removed after success, failure, or cancellation unless the configured `keep_fixes` rung preserves verified repair commits for the replacement train. Preserved fixes are replayed only when membership and source evidence match; conflicts or unverifiable commits are discarded safely.

## When a train does not land

A failure either defers members, leaving approval intact for an automatic retry, or rejects the landing and returns members to implemented for review. Transient infrastructure, stale-base, and temporary start blockers defer; grader or reconciliation failures reject. Structured failure reasons drive this choice, and missing diagnostics fall back to the Run's failure classification.

A train whose assembled changes are already on the base settles only members that can be verified as landed. A member that leaves landing before assembly causes a rebuild rather than a rejection.

Repositories can opt into a `multisect` failure rung. It runs visible prepare, evaluate, and collect Steps, uses `merge_train_multisect_section_width`, confirms omitted sections before attributing one member, and records the result without automatically withdrawing that member. Ambiguous, interacting, flaky, inherited, or non-reproducing results remain unattributed for operator review.

## Reconciliation phase

After building the integration branch, Syrus runs `merge_train_reconcile` on the recorded integration SHA before prepare, graders, coverage, and landing. This invokes the configured agent provider against the combined member work to inspect for cross-Job inconsistencies. If no reconciliation work is needed, no diff is treated as success. If focused reconciliation edits are needed, Syrus commits them onto the integration branch and updates the train's integration SHA.

If Syrus cannot check out the recorded integration SHA for reconciliation, the train fails with a rebuild-required classification instead of reconciling one arbitrary member branch.

Operator-facing states:
- **No-op reconciliation** — the train reports that reconciliation completed with no code changes and continues to graders.
- **Reconciliation commits** — the train reports that the agent committed focused integration fixes; those commits stay on the integration branch and must pass the normal gates before landing.
- **Reconciliation failure** — the train fails inside the merge-train workflow. Operators should inspect the failed `merge_train_reconcile` run and retry the merge train after addressing the cause; they should not create a standalone reconciliation Job for current Epics.

## Grader validation

Syrus then runs the required grader suite on the integration branch (same as `auto_merge`: `retry_until(graders, repair: landing_fix)`). Merge-train validation is pass/fail only and does not run `coverage_analyze`. If graders fail, the `landing_fix` agent repairs the integration branch, and graders re-run up to `grade_max_iterations` times.

If that normal bounded repair loop exhausts, merge trains get one additional
bounded agent rung, `merge_train_agent`. This agent receives the assembled
integration branch, the latest recorded failing set, and the train membership.
It may make a focused repair on the integration branch or withdraw one
evidence-backed culprit. A repair is not a merge decision: Syrus publishes the
repaired integration branch, runs prepare and the normal landing graders again,
and only then can `merge_train_land` run. A withdrawal stops the current train,
routes the culprit through normal landing failure handling so its approval is cleared
and it returns to `implemented`, and defers the other members back to
`approved` so the landing queue can rederive a train without the withdrawn
member. The agent writes a durable `merge_train_agent` workflow artifact
recording the action, evidence, and repair diff metadata or withdrawn member.

## Land phase

Syrus pushes and merges the integration branch through GitHub, refreshes the base, and verifies each member's changes are present before closing its PR and Job. A member without positive landing evidence remains open and follows the normal landing-failure path; Syrus never closes it merely because the train merged. Content-equivalent changes already present on the base count as landed.

If the base moves, Syrus rebases the integration, lets an agent resolve conflicts when needed, reruns required graders, and retries landing. A push-protection rejection follows the documented push-protection recovery policy rather than rewriting shared train history.

## Failure behavior

Failed trains clean up disposable branches and release their landing slot. Genuine validation failures clear member approval; transient and rebuild-required outcomes return members to approved. Repeated automatic failures are bounded and eventually require an explicit operator retry, preventing a fast failure from rebuilding indefinitely.

## Size limit

`AppSetting.merge_train_max_size` does **not** apply to an Epic train. An Epic
of any size lands as one train.

The cap bounds job bundles instead (see
[Epicless Job Bundling](epicless_job_bundling.md)), where every added member is
an unrelated change the others have never been tested against, so each one
makes a failure more likely. An Epic's children are a linear stack — each was
built and graded on top of its predecessor — which is the arrangement the cap
exists to approximate, so capping them guards against a risk the stack has
already removed.

The asymmetry also matters because an Epic lands all-or-nothing. A cap cannot
trim an Epic train the way it trims a job bundle; it can only refuse the Epic,
leaving every child waiting until an operator raises the number or splits the
Epic by hand.

## Same-Epic dependency satisfaction

Within an Epic, a child Job's dependency on a sibling is considered satisfied once the sibling is `approved` or `landing` (not just after it merges). This allows the full stack to flow into the landing queue together rather than waiting for sequential merges.
