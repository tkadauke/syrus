# Landing Queue

## Patient automatic rebases

System-origin rebases, including behind-base, landing repair, and recovered
base-health repair, wait when another first-class workflow is active for the
same publication branch. The rebase WorkUnit is retained with
`patient_rebase_waiting_for_active_workflow` and normal workflow admission
rechecks it after the blocking workflow finishes; the reconciler must not
cancel the older workflow as superseded while this wait is active.

UI and chat-agent rebase requests are recorded with their explicit origin and
retain preemption behavior. Cancelling a `chat_feedback` workflow before its
push records unapplied feedback and places a durable landing hold on the Job;
ordinary PR review polling does not clear that distinct attention reason, so
the missing feedback stays visible for operator follow-up.

The landing queue manages the flow from "approved" to "merged." Once a Job is approved, Syrus queues it for landing via the `auto_merge` workflow, `external_pr_merge` for externally filed PRs, or the unconditional `merge_train` path for Epic children.

## Approval and landing

Approval moves a Job into the landing queue. Ready work starts the appropriate landing workflow; blocked work remains approved with an operator-visible reason. Candidates are ordered by priority and FIFO approval time, while dependencies remain before dependents and Epic members remain one atomic unit.

When approval propagation is enabled, Syrus mirrors an eligible approval as a GitHub review. It uses the approving operator's connected GitHub identity when possible and falls back to the repository App for a true same-identity self-review. Propagation is skipped only when neither credential is available.

Jobs wait when another unit is landing, Epic siblings are not ready, a dependency or upstream Epic is incomplete, or strict broken-main policy pauses the repository. Inconclusive main health warns but does not block by itself.

## Broken-main policy and repository pauses

Repository risk posture chooses whether broken main pauses all landing or allows work whose failures are proven unrelated. Strict policy pauses the repository. Isolation policy permits unrelated work and inherited grader failures, while failures introduced by the candidate still block. Pull-request check gating is configured separately as `all`, `own_only`, or `none`.

Changing policy does not silently clear an existing pause. Use **Resume landing** on repository health after reviewing the condition. The landing queue shows the effective blocker, falling back to workflow or merge-train diagnostics when necessary.

## Failures that are not rejections

Landing failures are either deferrals or rejections. Deferrals keep approval and retry after transient infrastructure, stale-base, preparation, or start-blocker conditions. Genuine validation failures return work to implemented and clear approval. The recorded explanation and stable failure code make the decision auditable.

Before dispatch, Syrus rechecks current approval policy and approver access. A no-longer-valid approval blocks without being overrideable for solo Jobs, Epic trains, and bundles.

## Failing PR checks: inherited vs. introduced

Syrus compares failing check names on the candidate with settled failures on its base:

- `own` means the candidate introduces at least one failing check and cannot be overridden.
- `inherited` means all named failures also fail on the base; the default block is operator-overridable.
- `unknown` means evidence is incomplete and remains blocked conservatively.

An inherited name match is evidence, not proof: a broad check can hide additional failures. The per-repository `pr_check_gate` setting therefore controls whether all failures block, only own/unknown failures block, or checks are advisory. Mergeability, dependency, rebase, and sibling gates still apply. Job and landing views show candidate failures, base failures, and the compared base revision.

## known_flaky_failure_dismissal_enabled

When enabled, landing may dismiss a failing test only when recent evidence meets the configured confidence and sample thresholds for a known flaky test. The decision is auditable and never applies to failures without matching evidence. Disabling the setting makes all such failures block normally.

## isolated_repro_dismissal_enabled

When enabled, Syrus may run a clean isolated reproduction for a failing test. A conclusive clean reproduction can dismiss that failure; failed, unavailable, stale, or inconclusive reproduction evidence cannot. Evidence is scoped to the relevant source and test identity, expires according to policy, and is shown with the landing decision. The feature is off by default.

## The landing slot and blocks that cannot clear

Only one landing unit may occupy a repository's landing slot. Jobs blocked by an active landing unit, repository pause, urgent-work gate, dependency, or another external condition remain visible with the effective reason. Syrus releases stale ownership when no active work can clear it and does not let a failed or cancelled unit hold the slot indefinitely.

Temporary blockers are rechecked automatically. Conditions that require operator action remain blocked until that action occurs. A stalled urgent Job stops delaying unrelated landing after 30 minutes when it has no active work and is not already landing.

## Stopping a landing attempt

While a Job is `landing` -- solo (`auto_merge`/`external_pr_merge`) or as part
of an Epic merge train -- the Job detail page shows a **Stop Landing** button.
It is available to the owner, an admin, or a repository member with write access.

Stop Landing cancels the Job's active landing Workflow -- the solo
`auto_merge`/`external_pr_merge` Workflow, or the single Epic-wide
`merge_train` Workflow when the Job is a train member -- and reverts the Job
to `implemented`, clearing its approval the same way a genuine landing
failure does. This is
deliberate: an explicit stop should require the operator to re-approve before
Syrus attempts to land the Job again, not silently re-enter the landing
queue. For a merge-train member, stopping the train reverts every member Job
that hadn't already merged, the same as any other train failure or
cancellation.

Stop Landing does not close the Job (contrast with the general-purpose
**Cancel** button, which cancels active work and closes the Job entirely) --
the PR and branch stay intact for the operator to re-approve once ready.

## auto_merge workflow

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge`

### mergeability_preflight

Refreshes GitHub's mergeability status for the PR. When GitHub says the PR is
ready, Syrus first attempts a deterministic rebase onto the current base branch
and force-pushes it with `--force-with-lease` if the rebase changes the PR head.
Final graders then run against that rebased head. If the deterministic rebase
conflicts, Syrus dispatches a `rebase` workflow and defers. If GitHub is still
computing (`mergeable: null`), Syrus runs a local rebase preflight to distinguish
conflicts from GitHub lag. If a prior landing validation is still valid for the
current artifact, base, and grader configuration, skips grader re-validation and
logs the reuse reason.

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

If graders fail, `landing_fix` (an agentic repair step) attempts a fix, and
graders re-run. The repair budget counts committed repairs rather than raw
agent turns. A clean-tree turn with no structured resolution is classified as
an `inconclusive_no_op` and immediately regraded without spending a repair
iteration; two such turns stop the loop deterministically. Transient or
infrastructure-only failures have a separate one-rerun allowance. Each turn is
classified as `committed_repair`, `verified_no_change_resolution`,
`explicit_flaky_retry`, or `inconclusive_no_op`; workflow decision events and
the terminal `landing_repair_summary` expose both the repair and no-progress
counters.

For ordinary non-landing grader loops, the loop repeats up to
`grade_max_iterations` times unless it stops making progress. Progress means at least one previously failing grader
identity now passes: a round that fixes something still counts even if an
unrelated failure appears in the same round, because the failing set spans
every required grader at once. Two rounds end the loop early with
`needs_attention_reason: grader_loop_no_progress` — one that fixes nothing
(whether the failing set stood still or only grew), and one that returns to a
failing set an earlier round in the same loop already produced, which is how a
repair that trades failures round after round is caught. Required graders that
never reached a verdict — killed by a timeout, a dead worker, a full disk —
are left out of the comparison entirely, since they measure the worker rather
than the tree. The Workflow records
`grader_loop_progress` and `grader_loop_stop` artifacts with the per-round
grader results, failing set, and repair diff summary so an operator can split
targeted follow-up work without rerunning the same broad repair.

### Speculative landing validation

When the `landing_validation_prefetch` feature flag is enabled, a successful
landing grader loop can warm the next same-repository landing unit before the
current unit actually publishes to the base branch. Syrus dispatches an
infrastructure validation workflow for the next eligible unit:

- Ordinary owned-branch PRs use `landing_validation`.
- Epic merge-train units use `merge_train_validation`.

For an ordinary PR, the workflow:

- Clones the next PR branch.
- Fetches the current landing workflow's local `HEAD` as the predicted future base.
- Rebases the candidate onto that predicted base without pushing.
- Runs the same fast landing graders without `landing_fix`.
- Records validation evidence for the predicted base commit and tree.

For an Epic merge-train unit, the workflow builds the candidate integration tree
on top of the same predicted future base, mechanically rebases each member
branch into that scratch integration branch, and runs fast landing graders
without creating a real `MergeTrain`, pushing, or repairing.

The real `auto_merge` or `merge_train` workflow later reuses that validation
only if the candidate head/tree, base ref, base tree, grader fingerprint, and
changed-file fingerprint still match. A different base commit SHA is allowed
only when its Git tree SHA is identical to the predicted tree, which covers
GitHub rebase-merge producing a different commit object for the same contents.
If any identity differs, the normal serialized landing workflow reruns graders.

Speculative validation is not an additional landing lane. It never pushes,
merges, or repairs; a failed speculative workflow leaves the Job approved and
the normal landing queue path intact.

### push and auto_merge

After graders pass, Syrus pushes any repair commits and calls the GitHub merge API. The merge method (merge, squash, or rebase) is configured per-repository.

### Transient failures

If GitHub's merge API returns a transient error, the Job is deferred back to `approved` and retried. If GitHub returns 405 "PR can't be rebased," Syrus dispatches a `rebase` workflow instead of treating the attempt as terminal.

### After a successful merge

The Job transitions to `pr_merged`. If the merged PR was depended on by other Jobs, those dependencies are satisfied and their workflows unblocked.

## external_pr_merge workflow

**Step chain:** `mergeability_preflight → prepare → grader_fanout → grader_collect → external_pr_merge`

External PR Jobs use the GitHub PR as the source of truth instead of a Syrus-owned branch. The workflow refreshes GitHub mergeability, prepares the workspace so grader dependencies are installed, runs required graders against the external PR head, then calls GitHub's merge API for the external PR number. It still skips the normal `push` step.

For same-repository external PRs, `mergeability_preflight` first attempts a deterministic rebase of the PR head ref onto the current base branch and force-pushes it with `--force-with-lease` before landing graders run. If that deterministic rebase conflicts, Syrus dispatches the normal `rebase` workflow against the external PR's actual head branch and defers landing. Fork PRs skip this preflight rebase because Syrus cannot push their branches.

For same-repository external PRs, grader failures enter the `landing_fix` retry loop before merge. If the agent commits a repair, `external_pr_merge` pushes the local repair commit to the PR's actual head branch immediately before merging. For fork PRs, Syrus cannot push repairs; required grader failures post a `REQUEST_CHANGES` review and `fail_landing!` returns the Job to `implemented`.

## trust_clean_rebase_grade

When `trust_clean_rebase_grade` is enabled (off by default), a clean `rebase`
workflow can carry forward a prior green landing validation to the new
head/base pair. A clean merge-train rebase can do the same for a base-moved
Epic integration branch.

Carried validation retires the skipped grade loop so later landing steps do not
wait on work that will never run.

Grade carry-forward records fresh validation evidence for the post-rebase head,
tree, base, grader plan, and changed files. It only carries forward from a real
successful required-grader validation, not another carried result. With
`trust_clean_rebase_grade`, changed files are diagnostic rather than a veto;
the accepted risk is that a clean rebase onto a moved base changes the apparent
diff. Carry-forward is reported distinctly and never applied speculatively.

## Landing validation reuse

A successful required-grader validation may be reused only for the same candidate head and tree, base ref, required grader plan, and changed-file set. Non-speculative reuse also requires the same base commit. Entries older than seven days are rejected.

With `trust_clean_rebase_grade`, a successful validation can carry forward across a clean rebase onto a moved base when the base ref and required grader plan still match. Carry-forward must originate from a real successful validation, never another carried result, and is reported distinctly from exact-head reuse. Speculative validation never uses this exception. Audit logs explain every reuse or rerun decision.

## Dependency gating

A Job blocked on another Job will not enter the landing queue until the dependency closes with one of these reasons: `pr_merged`, `external_pr_merged`, `pr_approved`, or `no_changes`. Same-Epic dependencies are also satisfied once the upstream Job is `approved` or `landing`.

If the prerequisite Job closes unsuccessfully, including `cancelled`, dependents remain blocked with `dependency_failed` until an operator removes or overrides the dependency. Syrus should not keep creating maintenance rebase workflows for a dependent while it is in this permanent dependency-failed state.

Manual dependencies can opt into `satisfaction_mode: "closed"` for cleanup or
teardown gates that only need the target Job to reach any terminal close. In
that mode a cancelled dependency is satisfied. Normal implementation
dependencies default to `success`; use closed mode only when any terminal
outcome is explicitly acceptable.

Use `satisfaction_mode: "landed"` when the dependent must not execute until an upstream Job's change is actually on the landing branch. Implemented, approved, landing, and `pr_approved` states do not satisfy this gate. A successful landing closure requires durable evidence in `landed_sha`; `no_changes` is the exception and satisfies the gate only through that explicit successful closure, because it records that there was genuinely no change to land. Failed, cancelled, rejected, and other unsuccessful closures permanently produce `dependency_failed`. Landed dependencies accept only Job targets: an Epic's completion or atomic merge-train landing is not silently treated as proof that an individual Job change landed.

Manual Job-to-Job dependencies can also use `satisfaction_mode: "deployment_stage"` with `required_deployment_stage_name` to wait until the upstream Job reaches a configured repository `deployment_stages` entry. Deployment-stage dependencies are valid only for resolved Job targets. Syrus rejects them when the upstream repository has no deployment stage tracking or when the named stage is unknown, because otherwise the dependency could never unblock. A successfully closed upstream Job that has not reached the required stage is still waiting, not failed; an unsuccessfully closed upstream Job is still a failed dependency.

The default `success` mode has a narrower, execution-only exception: it may start on an `implemented` parent once that parent has a materialized branch, PR, and head SHA, as long as stack parent selection is unambiguous. Same-Epic parents retain that readiness in `approved` or `landing`; for approved same-Epic fan-in, Syrus may also create a prepared combined base branch and start the child there when all dependency PR branches merge cleanly. `landed`, `closed`, and `deployment_stage` do not use this early-execution exception.

Operators can add or remove manual dependencies from the Job detail page; admins can override the gate.

## Closed-PR resolution

When a PR is closed without GitHub marking it merged, Syrus inspects the branch against the PR base with `git cherry` and picks one of three outcomes:

- **`pr_merged`** — every commit on the branch has a patch-equivalent commit on the base. The work landed, even though this PR was not the thing GitHub merged: a merge train landed a rebased copy, or someone cherry-picked it. This is a landing, and recording it as anything else files real work as work that never happened.
- **`no_changes`** — the branch is not ahead of the base by a single commit. The agent genuinely produced nothing (the normal happy path for a survey-style cron Job).
- **`pr_closed`** — the branch still carries commits the base does not have.

`no_changes` and `pr_merged` both count as successful resolutions for dependency gates and landing queue wakeups; the distinction matters for attribution, not for gating.

## Advisory-only CI checks (`pr_check_gate: none`)

`pr_check_gate` has a third value. On `none` a pull request's CI
checks never gate landing — neither the Job's own cached `pr_checks_state` nor
its Epic siblings'. Both gates honour the same value, because a single sibling
with red or pending checks holds an entire Epic; leaving the sibling gate on
would make the setting a no-op for exactly the Jobs it exists for.

Nothing else about checks changes. Syrus still polls them, still
caches `pr_checks_state` for display, still records target health from them, and
still triggers main-branch repair and main-health polling on an inherited or
unknown attribution. They remain a signal that something may be broken; they
stop being a decision about whether work may land.

Choose it when a repository's own graders already cover what its CI runs. The
gate then adds no coverage and can only disagree, because the two execute in
different environments — a Node version difference is enough to have a CI job
red and its equivalent grader green on the same commit, and the gate will
believe the narrower suite. A deployment that cannot run its full grader set
itself should stay on `all`; that is what the default is for.

One consequence worth stating: CI repair for an approved Epic child is deferred
to the merge train,
on the premise that the train grades the integration branch and repairs it
there. While the checks gate held those members out of the queue, that premise
could not hold — repair waited for a train that the gate prevented from
starting. On `none` the train starts and `landing_fix` is what repairs the
members, which is what the deferral always assumed.

## Validation manifest and main-grading parity

Landing validation and main grading evaluate the same semantic grader
contract. Every landing-phase grade that passes records a **validation
manifest** (`landing_validation_manifest` workflow artifact, implemented by
`LandingValidationManifest`) bound to the exact SHA that is about to be
merged: the PR head for ordinary auto-merge, the integration SHA for a
merge train.

The manifest records:

- `head_sha`, `tree_sha`, `base_sha`, `base_ref` and the grader/changed-file
  fingerprints.
- `source_snapshot`: the source SHA the graders actually ran against.
- `targets`: one entry per grader target with its typed `GraderOutcome`
  (`passed`, `test_failed`, `infrastructure_failed`, `inconclusive`,
  `cancelled`), the reason, whether the result ran or was reused
  (`ran`, `carried_forward`, `target_health`), the command, environment and
  input fingerprints, and whether command/environment evidence exists.
- `ci_phase_target_set`: the targets the CI phase (what main grading runs)
  resolves for the same diff, with their fingerprints.

### Landing gate

`Steps::AutoMerge` and `Steps::MergeTrainLand` refuse to merge unless the
manifest for that exact SHA shows a conclusive pass for every required
target. Evidence for another SHA is never promoted to exact-SHA evidence,
even when the tree is identical; the only exception is an explicit,
operator-trusted clean-rebase carry-forward (`trust_clean_rebase_grade`),
which re-binds the manifest to the rebased SHA and records `carried_from_sha`.
A pass counts as evidence only with recorded command and environment
fingerprints; `source_binding` states whether the SHA came from an immutable
source snapshot or from the grading workspace HEAD. Landing fails with problem `landing_validation_unproven`
and a reason that names the target when a required result is:

| Blocker code | Meaning |
| --- | --- |
| `manifest_missing` | No manifest exists; re-run landing validation. |
| `sha_mismatch` | Evidence is for another SHA (the branch moved after grading). |
| `required_result_missing` | No required result was recorded. |
| `required_result_inconclusive` | Missing exit status, timeout, etc. -- never a verdict. |
| `required_result_infrastructure_failed` | The grader could not run; retry, do not repair code. |
| `required_result_failed` / `required_result_cancelled` | Not a green result. |
| `required_evidence_missing` | A pass without command/environment evidence. |
| `source_snapshot_mismatch` | Graders ran against a different snapshot SHA. |
| `ci_phase_target_set_unavailable` | The target set main grading will run could not be resolved (fail closed). |
| `ci_phase_target_not_validated` | An affected required CI-phase target has no passing landing result. |

Landing grading runs under the main-grading contract: for ordinary landing,
`LandingGraderPlan` adds every required CI-phase grader that is not already
part of the landing phase, filtered by the same target selection, so the
additional targets run on the exact SHA before merge.

The gate result is stored in the `landing_parity_gate` artifact, including
the `post_merge_delta`: CI-phase targets that main will run but landing did
not validate. Immutable prepare-layer reuse and target-graph caching are
unchanged; the environment fingerprint stays part of the parity comparison.

### Main grading

When a main grader workflow settles, `main_grading_parity` attributes every
selected target to matching pre-merge evidence or an explicit delta
(`not_selected_pre_merge`, `command_fingerprint_changed`,
`environment_fingerprint_changed`, `pre_merge_<outcome>`,
`no_pre_merge_evidence`). A delta means main runs that target itself before
the integration is declared healthy. It is diagnostic and never changes
health on its own.

Operators read both artifacts, plus the manifest summary, under
`validation_parity` in `GET /api/v1/admin/workflows/:id`.

### When main repair may still be spawned

Main repair remains an exceptional fallback. It may be spawned only when a
required target reaches `test_failed` (valid exit status plus captured
failure evidence) on the main commit: a regression introduced by a commit
that did not pass through Syrus landing (manual push, external merge), a
genuine post-merge interaction with a base that moved after validation, or a
post-merge delta target that fails. Inconclusive or infrastructure outcomes
never spawn repair.
